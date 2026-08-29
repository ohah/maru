const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
/// **중립 파일이 macOS 폴더에 있다**(`file_tree_backend`·`git_backend` 와 같은 부류 — layering §3.4 의
/// 후속 행이 이사를 예약해 뒀다). 본문에 네이티브 참조가 0 이고 `home` 경로만 받는다.
const agent_archive_backend = @import("platform/macos/agent_session_archive_backend.zig");
const file_tree_backend = @import("platform/macos/file_tree_backend.zig"); // 파일 트리 스캔 — 이름과 달리 모든 호스트에서 돈다(계약 §2m.3)
// W7.1 Win32 창. **최상위에서 import한다** — Win32를 부르는 본문은 `builtin.os.tag` 비교가 comptime 참이라
// 다른 타깃에서 의미 분석 자체가 되지 않는다(`cli/control_client.zig`의 게이트와 같은 원리).
const win32_window = maru.win32_window;
// W7.2a D3D11+DXGI 표시 경로. 창과 같은 이유로 최상위 import다(위 주석).
const d3d11_present = maru.d3d11_present;
// W7.2b 셀 인스턴스 드로우.
const d3d11_cells = maru.d3d11_cells;
// W7.3 DirectWrite 글리프 래스터라이저.
const dwrite_font = maru.dwrite_font;
// W7.2c 중립 텍스트 계약 어댑터와 프레임 빌더.
const win32_text = maru.win32_text;
const win32_terminal = maru.win32_terminal;
const cell_text = maru.cell_text; // 파일 트리 행의 셀 투영 — macOS·Windows 공유 모듈(FT3)
const chrome_draw_lowering = @import("platform/macos/chrome/chrome_draw_lowering.zig"); // 이름과 달리 ops → DrawList 낮추기는 CoreText 를 안 부른다 — 본문 참조 0 회(§2m.6 과 같은 방식으로 쟀다)
const system_text = @import("platform/macos/chrome/system_text.zig"); // 이름과 달리 두 OS 를 다 탄다 — Windows 는 §2m.18 이음매로 간다
const git_backend_mod = @import("platform/macos/git_backend.zig"); // 이름과 달리 두 OS 를 다 탄다 — Windows 갈래는 캡처 러너로 간다(§2m.9)
// W7.4a Win32 키 입력 → 중립 KeyEvent.
const win32_keys = maru.win32_keys;
// W7.4b Win32 클립보드(OSC 52 배수 + 붙여넣기).
const win32_clipboard = maru.win32_clipboard;
// W7.4d Win32 마우스 규칙(선택·스크롤·리포팅) — 전부 순수 함수다.
const win32_mouse = maru.win32_mouse;
const draw_host = maru.win32_draw_host;
/// W8.4⒞ — 소스 컨트롤 표면의 상태와 다시 그리기. **가드가 필요하다**: 이 파일의 최상위 선언이
/// `d3d11_cells.Cell` 같은 Windows 타입을 이름으로 쓰므로, 가드 없이 import 하면 다른 타깃에서
/// 분석돼 깨진다(배럴의 Windows 항목들이 같은 이유로 `else struct {}` 다).
const scm_surface = if (@import("builtin").os.tag == .windows) @import("platform/windows/win32_scm_surface.zig") else struct {};
/// 같은 가드·같은 이유(W8.5b — 에이전트 세션 도크).
const agent_surface = if (@import("builtin").os.tag == .windows) @import("platform/windows/win32_agent_surface.zig") else struct {};

// **그 파일의 테스트를 실제로 돌린다.** 위 import 는 `runWin32ScmDrawSmoke` 안에서만 쓰이는데,
// 테스트 아티팩트는 `main` 을 안 부르므로 그 함수가 분석되지 않아 **테스트가 한 줄도 안 돌았다**
// (실측: 추가 직후 `zig build test` 출력에 `win32_scm_surface` 가 0 회). 이 저장소가 §2m.18 에서
// 같은 것을 밟았다.
test {
    _ = scm_surface;
    _ = agent_surface;
}
// 짧은 대기(스모크 전용). `app/live_pty.zig`가 같은 이유로 같은 것을 쓴다 — std에 노출이 없다.
extern "c" fn usleep(usec: c_uint) c_int;
const session_host_entrypoint = @import("platform/macos/session_host/entrypoint.zig");
const session_host_build_options = @import("session_host_build_options");
const session_host_admin_cli = if (builtin.os.tag == .macos)
    @import("platform/macos/session_host/admin_cli.zig")
else
    struct {};
const session_host_attach_cli = if (builtin.os.tag == .macos)
    @import("platform/macos/session_host/external_attach_cli.zig")
else
    struct {};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    // `error.UnknownCommand`는 "usage 에러를 이미 stderr에 안내했다"는 sentinel이다. main 밖으로 전파시키면 Zig가
    // 스택 트레이스를 덤프하고(사용자 오타에 crash처럼 보임) 버퍼된 안내 메시지도 유실된다. 여기서 잡아 stderr/stdout을
    // 확실히 flush한 뒤 코드 1로 깔끔히 종료한다(트레이스 없음). 그 밖의 진짜 오류는 그대로 전파(디버그 트레이스 유지).
    dispatch(init, stdout, stderr) catch |err| switch (err) {
        error.UnknownCommand => {
            stderr.flush() catch {};
            stdout.flush() catch {};
            std.process.exit(1);
        },
        else => return err,
    };
}

fn dispatch(
    init: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();

    const command = args.next() orelse {
        try printSmoke(stdout);
        return;
    };

    if (std.mem.eql(u8, command, "demo")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        try runDemo(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "win32-window-smoke")) {
        try runWin32WindowSmoke(allocator, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "d3d11-present-smoke")) {
        try runD3d11PresentSmoke(allocator, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "d3d11-cells-smoke")) {
        try runD3d11CellsSmoke(allocator, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "dwrite-text-smoke")) {
        try runDwriteTextSmoke(allocator, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "win32-frame-smoke")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        try runWin32FrameSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-git-smoke")) {
        try runWin32GitSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-scm-draw-smoke")) {
        try runWin32ScmDrawSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-scm-write-smoke")) {
        try runWin32ScmWriteSmoke(io, allocator, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "win32-file-tree-draw-smoke")) {
        try runWin32FileTreeDrawSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-editor-draw-smoke")) {
        try runWin32EditorDrawSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-file-tree-smoke")) {
        try runWin32FileTreeSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-terminal-smoke")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        // 스모크는 **상한이 있어야 한다** — 사람이 안 닫아도 끝나야 CI·자동 캡처가 성립한다.
        try runWin32Terminal(io, allocator, stdout, stderr, smoke_spin_cap);
        return;
    }
    if (std.mem.eql(u8, command, "win32-terminal")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        // **같은 코드 경로다.** 다른 것은 상한 하나뿐이라 "스모크에서는 되는데 앱에서는 안 되는" 자리가
        // 안 생긴다. 창을 닫을 때까지 돈다.
        try runWin32Terminal(io, allocator, stdout, stderr, null);
        return;
    }

    if (std.mem.eql(u8, command, "win32-clipboard-smoke")) {
        try runWin32ClipboardSmoke(allocator, stdout, stderr, args.next());
        return;
    }

    if (std.mem.eql(u8, command, "app-smoke")) {
        try runAppSmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "app-loop-smoke")) {
        try runAppLoopSmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "app-pty-loop-smoke")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        try runAppPtyLoopSmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "app-pty-interactive-loop-smoke")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        try runAppPtyInteractiveLoopSmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "app-pty-smoke")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        try runAppPtySmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "ssh")) {
        try runSsh(io, allocator, &args, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "install-cli")) {
        try runInstallCli(io, allocator, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "terminfo")) {
        try runTerminfo(allocator, &args, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "sessions")) {
        try runSessionCli(io, allocator, &args, stdout, stderr, .sessions);
        return;
    }

    if (std.mem.eql(u8, command, "session")) {
        try runSessionCli(io, allocator, &args, stdout, stderr, .session);
        return;
    }

    if (std.mem.eql(u8, command, "incidents")) {
        try runIncidentsCli(io, allocator, &args, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "host")) {
        try runPersistentReadCli(io, allocator, &args, stdout, stderr, .host);
        return;
    }

    if (std.mem.eql(u8, command, "runtime")) {
        try runPersistentReadCli(io, allocator, &args, stdout, stderr, .runtime);
        return;
    }

    if (std.mem.eql(u8, command, "attach")) {
        try runAttachCli(io, allocator, &args, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "control")) {
        try runControl(io, allocator, &args, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "agent-events")) {
        try runAgentEvents(io, allocator, &args, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "browser")) {
        try maru.cli.browser_run.run(io, allocator, &args, stdout, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "trace")) {
        try runTrace(io, allocator, &args, stdout, stderr);
        return;
    }

    // hidden: `maru __session-host <socket>` — 영속 세션 host 프로세스 본체(§10, P3-d2c/d). 앱이 detached spawn한
    // 자식이 이 인자로 재실행돼 host 모드로 진입한다(사용자가 직접 칠 명령이 아니라 usage에 안 넣는다). macOS 전용.
    if (std.mem.eql(u8, command, session_host_entrypoint.subcommand)) {
        try runSessionHostDaemon(io, allocator, &args, stderr);
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try printUsage(stdout);
        return;
    }

    try stderr.print("unknown maru command: {s}\n\n", .{command});
    try printUsage(stderr);
    return error.UnknownCommand;
}

/// 이 호스트의 홈 디렉터리(없으면 null). 환경변수를 읽는 **I/O만** 여기서 하고 판정은
/// `maru.user_paths.homeDirFor`(순수·OS 인자)가 한다 — 규칙이 갈리지 않게 네 소비자가 이 함수 하나를 쓴다
/// (terminfo 캐시 · `install-cli` 위치 · ssh control path · `trace anonymize`의 매칭 키).
///
/// 반환 슬라이스는 **프로세스 수명 동안 유효**하다(호출자 넷이 free하지 않는다). 예전에는 환경 블록을
/// 그대로 borrow했는데, 이제는 한 번 읽어 아래 고정 버퍼에 담고 그것을 빌려준다 — 소유권 계약은 그대로다.
///
/// **`std.c.getenv`를 쓰지 않는다.** Windows에서 그것은 CRT의 **ANSI 환경**이라 사용자명이 비-ASCII면
/// 값이 ACP 바이트로 온다(실측: `C:\Users\홍길동\…`가 cp949, `valid_utf8=false`). 그 바이트로 파일을
/// 열면 실패하고, 이 함수의 소비자 넷(terminfo 캐시·`install-cli` 위치·ssh control path·
/// `trace anonymize` 매칭 키)이 전부 조용히 어긋난다. 자세한 근거는 `os_env`의 doc에.
var host_home_buf: [1024]u8 = undefined;
var host_home_len: usize = 0;
var host_home_resolved: bool = false;

fn hostHomeDir() ?[]const u8 {
    if (host_home_resolved) return if (host_home_len == 0) null else host_home_buf[0..host_home_len];
    host_home_resolved = true;

    const gpa = std.heap.smp_allocator;
    const home = maru.os_env.allocValue(gpa, "HOME");
    defer if (home) |h| gpa.free(h);
    const userprofile = maru.os_env.allocValue(gpa, "USERPROFILE");
    defer if (userprofile) |u| gpa.free(u);

    const picked = maru.user_paths.homeDirFor(@import("builtin").os.tag, home, userprofile) orelse return null;
    // 홈 경로가 버퍼를 넘으면 **자르지 않고 없는 것으로 본다** — 잘린 경로는 다른 디렉터리를 가리켜
    // 그 아래에 파일을 쓰는 소비자(terminfo 캐시·install-cli)가 엉뚱한 자리를 만든다.
    if (picked.len == 0 or picked.len > host_home_buf.len) return null;
    @memcpy(host_home_buf[0..picked.len], picked);
    host_home_len = picked.len;
    return host_home_buf[0..host_home_len];
}

/// `maru win32-window-smoke` — W7.1이 actual로 무엇을 하는지 사람이 눈으로 확인하는 자리.
///
/// 창을 만들고 잠깐 펌프하며 **중립 이벤트**를 세어 보고한다. 아직 아무것도 그리지 않는다 — 그리는 것은
/// W7.2(D3D11+DXGI)다. 그래서 보이는 것은 빈 창이고, 이 스모크가 증명하는 것은 "창이 뜨고 OS 이벤트가
/// 앱 어휘로 도착한다"까지다.
///
/// **창을 못 만드는 환경이 있다.** 대화형 데스크톱이 없으면(서비스·일부 CI) `CreateWindowExW`가 실패한다.
/// 다만 실패를 곧바로 "데스크톱이 없다"로 읽지 마라 — 우리가 그렇게 오진했다. 이 개발기는 `WinSta0\Default`
/// 의 활성 콘솔 세션이었는데도 오류 8로 실패했고, 원인은 **데스크톱 힙 고갈**이었다(고아 프로세스 8,606개;
/// 그 상태에선 notepad도 안 떴다). 그래서 실패 안내가 오류 코드를 그대로 보여 주고 8을 따로 짚는다.
fn runWin32WindowSmoke(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-window-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.1 window smoke)");
    var window = win32_window.Window.create(allocator, title, 960, 600) catch |err| {
        try stderr.print("maru win32-window-smoke: could not create the window({s}, Win32 error {d})\n", .{ @errorName(err), win32_window.last_create_error });
        try stderr.writeAll("  this is expected where there is no interactive desktop (CI, services, remote automation) — run it in a normal session.\n");
        // 오류 8을 따로 말한다. 이름은 메모리지만 actual로는 **데스크톱 힙** 고갈이고, 그때는 세션 전체가
        // 창을 못 만든다(실측: 고아 프로세스 8,606개가 쌓여 notepad조차 뜨지 않았다). 이 구분이 없으면
        // 앱 버그로 오진한다 — 우리가 그렇게 한 번 헤맸다.
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  error 8 (ERROR_NOT_ENOUGH_MEMORY) usually means the desktop heap is exhausted — check how many processes this session has.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    var resized: usize = 0;
    var painted: usize = 0;
    var close_requested = false;
    var spins: usize = 0;
    // 짧게 돈다 — 이것은 앱 루프가 아니라 계약 스모크다. 사용자가 창을 닫으면 즉시 끝난다.
    while (spins < 240 and !window.quit_requested and !close_requested) : (spins += 1) {
        for (window.poll()) |ev| switch (ev) {
            .resized => resized += 1,
            .paint => painted += 1,
            .close_requested => close_requested = true,
            // 이 스모크는 창 계약만 본다 — 입력은 W7.4a 의 터미널 스모크가 검증한다.
            .key => {},
            .preedit_changed => {},
            // 이 스모크는 마우스를 안 본다 — 선택·스크롤은 W7.4d 의 터미널 스모크가 검증한다.
            .mouse => {},
        };
        _ = usleep(8_000); // 8ms — 스모크가 CPU를 태우지 않게. 프레임 페이싱은 W7.2 몫이다.
    }
    if (close_requested) window.requestClose();

    try stdout.writeAll("maru.win32-window-smoke.v1\n");
    try stdout.print("resized_events={d}\n", .{resized});
    try stdout.print("paint_events={d}\n", .{painted});
    try stdout.print("close_requested={}\n", .{close_requested});
    try stdout.print("dropped_events={d}\n", .{window.events.dropped});
    if (window.clientSize()) |c| {
        try stdout.print("client_px={d}x{d}\n", .{ c.width_px, c.height_px });
        if (win32_window.cellsForClient(c.width_px, c.height_px, 8, 16)) |size|
            try stdout.print("cells_at_8x16={d}x{d}\n", .{ size.cols, size.rows });
    }
    try stdout.writeAll("visible UI: the window appears only. Drawing is W7.2 (D3D11+DXGI); input is W7.4.\n");
    try stdout.flush();
}

/// `maru d3d11-present-smoke` — W7.2a. **창이 GPU로 칠해지는 것까지**를 사람이 눈으로 확인하는 자리.
///
/// W7.1 스모크와 갈라 둔 이유: 실패가 창에서 났는지 표시 경로에서 났는지 한 층씩 보여야 한다. 여기서
/// 증명하는 것은 "D3D11 디바이스와 DXGI 스왑체인이 서고, 리사이즈를 따라가고, present가 화면에 닿는다"
/// 까지다. 셀·글리프는 W7.2b다 — 그래서 지금은 **테마 배경 한 색**만 칠한다.
fn runD3d11PresentSmoke(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru d3d11-present-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.2a D3D11 present smoke)");
    var window = win32_window.Window.create(allocator, title, 960, 600) catch |err| {
        try stderr.print("maru d3d11-present-smoke: could not create the window({s}, Win32 error {d})\n", .{ @errorName(err), win32_window.last_create_error });
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  error 8 (ERROR_NOT_ENOUGH_MEMORY) usually means the desktop heap is exhausted — check how many processes this session has.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    // `orelse`의 두 갈래는 타입이 같아야 한다 — 익명 리터럴은 `?ClientSize`의 payload로 추론되지 않는다.
    const initial = window.clientSize() orelse win32_window.ClientSize{ .width_px = 960, .height_px = 600 };
    var present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
        try stderr.print("maru d3d11-present-smoke: could not set up the present path({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
        try stderr.writeAll("  this is expected where the GPU/driver cannot provide D3D11 (some CI and remote sessions).\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer present.destroy();
    // 창이 표시 대상을 **만들지 않고 받는다**(W7.1의 이음매). 여기가 그것을 채우는 유일한 자리다.
    window.present.opaque_handle = @ptrCast(present);

    // 터미널 테마 기본 배경과 같은 표현(0xAARRGGBB)을 쓴다 — W7.2c가 actual `terminal_bg`를 넣을 자리다.
    const clear = d3d11_present.clearColorFromArgb(0xFF1E2430);

    var frames: usize = 0;
    var resizes: usize = 0;
    var close_requested = false;
    var spins: usize = 0;
    while (spins < 240 and !window.quit_requested and !close_requested) : (spins += 1) {
        for (window.poll()) |ev| switch (ev) {
            .resized => |r| {
                resizes += 1;
                // 최소화(0×0)에서도 부른다 — `resize`가 1로 올려 스왑체인을 살려 둔다.
                present.resize(r.width_px, r.height_px) catch |err| {
                    try stderr.print("resize failed: {s} (HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
                    try stderr.flush();
                    return error.UnknownCommand;
                };
            },
            .paint => {},
            .close_requested => close_requested = true,
            .key => {},
            .preedit_changed => {},
            // 이 스모크는 마우스를 안 본다 — 선택·스크롤은 W7.4d 의 터미널 스모크가 검증한다.
            .mouse => {},
        };
        present.clearAndPresent(clear, false) catch |err| {
            try stderr.print("present failed: {s} (HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
            try stderr.flush();
            return error.UnknownCommand;
        };
        frames += 1;
        _ = usleep(8_000); // 8ms — vsync를 끄고 돌리므로 스모크가 CPU를 태우지 않게.
    }
    if (close_requested) window.requestClose();

    try stdout.writeAll("maru.d3d11-present-smoke.v1\n");
    try stdout.print("frames_presented={d}\n", .{frames});
    try stdout.print("resize_events={d}\n", .{resizes});
    try stdout.print("close_requested={}\n", .{close_requested});
    try stdout.print("swapchain_px={d}x{d}\n", .{ present.width_px, present.height_px });
    // 어느 드라이버로 섰는지 숨기지 않는다 — WARP로 떨어졌는데 모르면 성능을 잘못 판정한다.
    try stdout.print("driver={s}\n", .{@tagName(present.driver)});
    try stdout.print("clear_argb=0x{X:0>8}\n", .{@as(u32, 0xFF1E2430)});
    try stdout.writeAll("visible UI: the window is filled with the theme background. Cells and glyphs are W7.2b; input is W7.4.\n");
    try stdout.flush();
}

/// W7.2b 스모크가 아틀라스에 채워 넣는 코드포인트. **폰트를 쓰지 않는다** — `renderer.synthesizeGlyph`가
/// codepoint에서 직접 픽셀을 만드는 것들만 골랐다(box-drawing·block·braille). 그래서 W7.3(DirectWrite)
/// 전에도 "아틀라스에서 커버리지를 읽어 셀에 칠한다"는 경로 전체가 actual 픽셀로 검증된다.
const cells_smoke_codepoints = [_]u32{
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, // 직선·모서리·T
    0x252C, 0x2534, 0x253C, 0x2550, 0x2551, 0x2554, 0x2557, 0x255A, // 사거리·이중선
    0x2588, 0x2592, 0x2584, 0x2580, 0x258C, 0x2590, 0x2596, 0x259A, // block·shade·half
    0x28FF, 0x2801, 0x2847, 0x28B6, // braille
};

/// `maru d3d11-cells-smoke` — W7.2b. **글리프가 화면에 나오는 것까지**를 사람이 눈으로 확인하는 자리.
///
/// W7.2a가 "창이 한 색으로 칠해진다"였다면 여기는 "셀 격자에 배경색과 글리프가 각각 제자리에 그려진다"다.
/// 아직 actual 터미널 화면이 아니다(W7.2c가 `app.host` 프레임을 물린다) — 여기서 그리는 것은 이 스모크가
/// 직접 만든 격자다. 그래도 아틀라스 업로드·UV 변환·인스턴스 드로우·블렌드가 전부 진짜 경로다.
fn runD3d11CellsSmoke(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru d3d11-cells-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    const cell_w: u32 = 16;
    const cell_h: u32 = 32;

    // ── 아틀라스를 합성 글리프로 채운다 ────────────────────────────────────────────────────
    // 슬롯 0은 **비워 둔다** — 글리프 없는 셀이 가리킬 자리다(커버리지 0이라 배경만 남는다).
    const slots: u32 = cells_smoke_codepoints.len + 1;
    const atlas_w = cell_w * slots;
    const atlas_h = cell_h;
    const bytes_per_row: usize = @as(usize, atlas_w) * 4;
    const atlas_pixels = try allocator.alloc(u8, bytes_per_row * atlas_h);
    defer allocator.free(atlas_pixels);
    @memset(atlas_pixels, 0);

    // **슬롯마다 따로 그린 뒤 옮겨 붙인다.** 넓은 아틀라스 중간으로 오프셋한 슬라이스를 그대로 넘기면
    // 안 된다 — `synthesizeGlyph`는 `len >= height * bytes_per_row`를 요구하는데 오프셋한 슬라이스는
    // 꼬리가 모자라 **빈 글리프로 안전 degrade**한다. 실측으로 겪었다: 슬롯 28개가 "채워졌다"고 나오면서
    // actual 덮인 픽셀은 0이었다(그래서 이 수를 따로 세어 보고한다 — 안 그러면 성공으로 보인다).
    const slot_bpr: usize = @as(usize, cell_w) * 4;
    const scratch = try allocator.alloc(u8, slot_bpr * cell_h);
    defer allocator.free(scratch);

    var filled_slots: usize = 0;
    var filled_pixels: u32 = 0;
    for (cells_smoke_codepoints, 0..) |cp, i| {
        @memset(scratch, 0);
        const n = maru.renderer.synthesizeGlyph(cp, cell_w, cell_h, slot_bpr, scratch) orelse continue;
        filled_slots += 1;
        filled_pixels += n;

        const x_px = (i + 1) * cell_w;
        var y: usize = 0;
        while (y < cell_h) : (y += 1) {
            const src = scratch[y * slot_bpr ..][0..slot_bpr];
            const dst_off = y * bytes_per_row + x_px * 4;
            @memcpy(atlas_pixels[dst_off..][0..slot_bpr], src);
        }
    }

    // ── 창과 표시 경로 ─────────────────────────────────────────────────────────────────────
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.2b D3D11 cells smoke)");
    var window = win32_window.Window.create(allocator, title, 960, 600) catch |err| {
        try stderr.print("maru d3d11-cells-smoke: could not create the window({s}, Win32 error {d})\n", .{ @errorName(err), win32_window.last_create_error });
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  error 8 (ERROR_NOT_ENOUGH_MEMORY) usually means the desktop heap is exhausted — check how many processes this session has.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    const initial = window.clientSize() orelse win32_window.ClientSize{ .width_px = 960, .height_px = 600 };
    var present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
        try stderr.print("maru d3d11-cells-smoke: could not set up the present path({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer present.destroy();
    window.present.opaque_handle = @ptrCast(present);

    var pipeline = d3d11_cells.CellPipeline.create(allocator, present.device, present.context, atlas_w, atlas_h, atlas_pixels) catch |err| {
        try stderr.print("maru d3d11-cells-smoke: could not set up the cell pipeline({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_cells.last_hresult)) });
        if (d3d11_cells.shaderError().len > 0)
            try stderr.print("  shader compiler: {s}\n", .{d3d11_cells.shaderError()});
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer pipeline.destroy();

    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer cells.deinit(allocator);

    const clear = d3d11_present.clearColorFromArgb(0xFF1E2430);
    var frames: usize = 0;
    var close_requested = false;
    var spins: usize = 0;
    var last_cell_count: usize = 0;
    while (spins < 240 and !window.quit_requested and !close_requested) : (spins += 1) {
        for (window.poll()) |ev| switch (ev) {
            .resized => |r| try present.resize(r.width_px, r.height_px),
            .paint => {},
            .close_requested => close_requested = true,
            .key => {},
            .preedit_changed => {},
            // 이 스모크는 마우스를 안 본다 — 선택·스크롤은 W7.4d 의 터미널 스모크가 검증한다.
            .mouse => {},
        };

        const size = win32_window.cellsForClient(present.width_px, present.height_px, cell_w, cell_h) orelse continue;
        cells.clearRetainingCapacity();
        var row: u32 = 0;
        while (row < size.rows) : (row += 1) {
            var col: u32 = 0;
            while (col < size.cols) : (col += 1) {
                // 격자무늬 배경 — 배경 알파가 actual로 판정에 쓰이는지 보이게 한다. 알파 0인 셀은
                // clear color 가 그대로 비쳐야 한다(그것이 `NativeMetalCell`의 규약이다).
                const checker = (row + col) % 3 == 0;
                const bg: u32 = if (checker) 0xFF2E3A4E else 0x00000000;
                // 글리프는 슬롯을 순환시킨다. 첫 열은 슬롯 0(빈 글리프)이라 배경만 나온다.
                const slot: u32 = if (col == 0) 0 else @intCast(1 + ((row * size.cols + col) % cells_smoke_codepoints.len));
                try cells.append(allocator, .{
                    .rect = .{
                        @floatFromInt(col * cell_w),
                        @floatFromInt(row * cell_h),
                        @floatFromInt(cell_w),
                        @floatFromInt(cell_h),
                    },
                    .uv = d3d11_cells.uvFromAtlasRect(slot * cell_w, 0, cell_w, cell_h, atlas_w, atlas_h),
                    .fg = d3d11_cells.colorFromArgb(0xFFD8E0F0),
                    .bg = d3d11_cells.colorFromArgb(bg),
                });
            }
        }
        last_cell_count = cells.items.len;

        try present.beginFrame(clear);
        pipeline.draw(cells.items, present.width_px, present.height_px) catch |err| {
            try stderr.print("draw failed: {s} (HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_cells.last_hresult)) });
            try stderr.flush();
            return error.UnknownCommand;
        };
        try present.present(false);
        frames += 1;
        _ = usleep(8_000);
    }
    if (close_requested) window.requestClose();

    try stdout.writeAll("maru.d3d11-cells-smoke.v1\n");
    try stdout.print("frames_presented={d}\n", .{frames});
    try stdout.print("atlas_px={d}x{d}\n", .{ atlas_w, atlas_h });
    try stdout.print("atlas_slots={d} filled={d}\n", .{ slots, filled_slots });
    try stdout.print("atlas_covered_pixels={d}\n", .{filled_pixels});
    try stdout.print("cells_drawn={d}\n", .{last_cell_count});
    try stdout.print("swapchain_px={d}x{d}\n", .{ present.width_px, present.height_px });
    try stdout.print("driver={s}\n", .{@tagName(present.driver)});
    try stdout.writeAll("visible UI: the cell grid is drawn with background colors and synthesized glyphs. Font glyphs are W7.3; the real terminal screen is W7.2c.\n");
    try stdout.flush();
}

/// W7.3 스모크가 그리는 화면. **두 경로가 한 화면에 나오게** 짰다 — 글자는 DirectWrite가 래스터화하고,
/// 테두리와 블록은 `renderer.synthesizeGlyph`가 코드포인트에서 합성한다. 둘이 같은 아틀라스·같은 셰이더를
/// 지나므로, 한쪽만 나오면 어느 경로가 죽었는지 화면으로 바로 갈린다.
const dwrite_smoke_lines = [_][]const u8{
    "┌──────────────────────────────────────────────┐",
    "│ maru on Windows — W7.3 DirectWrite           │",
    "│                                              │",
    "│  ABCDEFGHIJKLMNOPQRSTUVWXYZ                  │",
    "│  abcdefghijklmnopqrstuvwxyz                  │",
    "│  0123456789  !@#$%^&*()  {}[]<>  +-*/=       │",
    "│                                              │",
    "│  $ zig build test                            │",
    "│  All 2636 tests passed.                      │",
    "│                                              │",
    "│  text is DirectWrite, borders are synthesized glyphs   │",
    "│  ▁▂▃▄▅▆▇█  ░▒▓  ╔═╗ ╠═╣ ╚═╝                  │",
    "└──────────────────────────────────────────────┘",
};

/// `maru dwrite-text-smoke` — W7.3. **글자가 화면에 나오는 것까지**를 사람이 눈으로 확인하는 자리.
///
/// 셀 격자·아틀라스·인스턴스 드로우는 W7.2b가 세운 것을 그대로 쓴다. 이 슬라이스가 더하는 것은
/// **DirectWrite가 코드포인트를 커버리지 픽셀로 바꾸는 경로** 하나다. 그래서 화면에서 글자가 읽히면
/// 그 경로가 산 것이고, 테두리만 보이면 죽은 것이다.
fn runDwriteTextSmoke(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru dwrite-text-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    // config `font.family`가 비어 있는 경우를 흉내 낸다 — 티어가 actual로 폰트를 고르는지 보려면
    // 여기서 이름을 박지 않아야 한다(§3.1a의 셸 티어와 같은 판정).
    var raster = dwrite_font.Rasterizer.create(allocator, "", "", 18.0) catch |err| {
        try stderr.print("maru dwrite-text-smoke: could not set up the font({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(dwrite_font.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer raster.destroy();

    const cell_w = raster.metrics.width_px;
    const cell_h = raster.metrics.height_px;

    // ── 나올 코드포인트를 모아 아틀라스 슬롯을 배정한다 ────────────────────────────────────
    //
    // **슬롯 폭이 코드포인트마다 다르다.** 한글·CJK는 두 칸을 차지하므로(`terminal.cellWidth`) 슬롯도 두 칸
    // 폭으로 잡고 화면에서도 두 칸에 걸쳐 그린다. 한 칸에 밀어 넣으면 글자가 반으로 잘린다.
    const Slot = struct { x_px: u32, w_cells: u32 };
    var slot_of = std.AutoHashMap(u32, Slot).init(allocator);
    defer slot_of.deinit();
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(allocator);

    var next_x: u32 = cell_w; // 슬롯 0(폭 1칸)은 비워 둔다 — 글리프 없는 셀이 가리킬 자리다.
    var max_cols: usize = 0;
    for (dwrite_smoke_lines) |line| {
        var cols: usize = 0;
        var it = (std.unicode.Utf8View.init(line) catch continue).iterator();
        while (it.nextCodepoint()) |cp| {
            const w: u32 = @max(1, maru.terminal.cellWidth(@intCast(cp)));
            cols += w;
            if (cp == ' ') continue;
            if (slot_of.get(cp) != null) continue;
            try slot_of.put(cp, .{ .x_px = next_x, .w_cells = w });
            try order.append(allocator, cp);
            next_x += cell_w * w;
        }
        max_cols = @max(max_cols, cols);
    }

    const slots: u32 = @intCast(order.items.len + 1);
    const atlas_w = next_x;
    const atlas_h = cell_h;
    const bytes_per_row: usize = @as(usize, atlas_w) * 4;
    const atlas_pixels = try allocator.alloc(u8, bytes_per_row * atlas_h);
    defer allocator.free(atlas_pixels);
    @memset(atlas_pixels, 0);

    // 슬롯마다 따로 그린 뒤 옮겨 붙인다(W7.2b에서 배운 것 — 오프셋 슬라이스는 조용히 빈 글리프가 된다).
    // 버퍼는 **가장 넓은 슬롯**(두 칸)에 맞춰 한 번 잡고, 슬롯마다 필요한 만큼만 쓴다.
    const wide_bpr: usize = @as(usize, cell_w) * 2 * 4;
    const slot_buf = try allocator.alloc(u8, wide_bpr * cell_h);
    defer allocator.free(slot_buf);
    const scratch = try allocator.alloc(u8, dwrite_font.Rasterizer.scratchSize(cell_w * 2, cell_h));
    defer allocator.free(scratch);

    var synth_slots: usize = 0;
    var font_slots: usize = 0;
    var blank_slots: usize = 0;
    var covered_total: u32 = 0;
    for (order.items) |cp| {
        const slot = slot_of.get(cp).?;
        const slot_w = cell_w * slot.w_cells;
        const slot_bpr: usize = @as(usize, slot_w) * 4;
        const used = slot_buf[0 .. slot_bpr * cell_h];
        @memset(used, 0);

        // **합성이 먼저다.** 중립 계약이 정한 dispatch 순서다 — box-drawing·block을 폰트로 그리면
        // 셀에 안 맞아 이음매가 생긴다.
        var covered: u32 = 0;
        if (maru.renderer.synthesizeGlyph(cp, slot_w, cell_h, slot_bpr, used)) |n| {
            covered = n;
            synth_slots += 1;
        } else {
            covered = raster.rasterize(cp, slot_w, cell_h, slot_bpr, used, scratch) catch |err| blk: {
                try stderr.print("  warning: U+{X:0>4} rasterization failed({s})\n", .{ cp, @errorName(err) });
                break :blk 0;
            };
            if (covered > 0) font_slots += 1 else blank_slots += 1;
        }
        covered_total += covered;

        var y: usize = 0;
        while (y < cell_h) : (y += 1) {
            @memcpy(atlas_pixels[y * bytes_per_row + slot.x_px * 4 ..][0..slot_bpr], used[y * slot_bpr ..][0..slot_bpr]);
        }
    }

    // ── 창·표시 경로·파이프라인 ────────────────────────────────────────────────────────────
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.3 DirectWrite text smoke)");
    const want_w: i32 = @intCast(@min(@as(usize, 1600), (max_cols + 2) * cell_w + 24));
    const want_h: i32 = @intCast(@min(@as(usize, 1200), (dwrite_smoke_lines.len + 2) * cell_h + 60));
    var window = win32_window.Window.create(allocator, title, want_w, want_h) catch |err| {
        try stderr.print("maru dwrite-text-smoke: could not create the window({s}, Win32 error {d})\n", .{ @errorName(err), win32_window.last_create_error });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    const initial = window.clientSize() orelse win32_window.ClientSize{ .width_px = 960, .height_px = 600 };
    var present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
        try stderr.print("maru dwrite-text-smoke: could not set up the present path({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer present.destroy();
    window.present.opaque_handle = @ptrCast(present);

    var pipeline = d3d11_cells.CellPipeline.create(allocator, present.device, present.context, atlas_w, atlas_h, atlas_pixels) catch |err| {
        try stderr.print("maru dwrite-text-smoke: could not set up the cell pipeline({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_cells.last_hresult)) });
        if (d3d11_cells.shaderError().len > 0)
            try stderr.print("  shader compiler: {s}\n", .{d3d11_cells.shaderError()});
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer pipeline.destroy();

    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer cells.deinit(allocator);

    const clear = d3d11_present.clearColorFromArgb(0xFF1E2430);
    const fg = d3d11_cells.colorFromArgb(0xFFD8E0F0);
    const bg_none = d3d11_cells.colorFromArgb(0x00000000);
    var frames: usize = 0;
    var close_requested = false;
    var spins: usize = 0;
    while (spins < 300 and !window.quit_requested and !close_requested) : (spins += 1) {
        for (window.poll()) |ev| switch (ev) {
            .resized => |r| try present.resize(r.width_px, r.height_px),
            .paint => {},
            .close_requested => close_requested = true,
            .key => {},
            .preedit_changed => {},
            // 이 스모크는 마우스를 안 본다 — 선택·스크롤은 W7.4d 의 터미널 스모크가 검증한다.
            .mouse => {},
        };

        cells.clearRetainingCapacity();
        for (dwrite_smoke_lines, 0..) |line, row| {
            var col: usize = 0;
            var it = (std.unicode.Utf8View.init(line) catch continue).iterator();
            while (it.nextCodepoint()) |cp| {
                const w: u32 = @max(1, maru.terminal.cellWidth(@intCast(cp)));
                const slot = slot_of.get(cp) orelse Slot{ .x_px = 0, .w_cells = 1 };
                // 두 칸 글자는 **셀 하나를 두 칸 폭으로** 그린다 — 셀 둘로 쪼개면 UV를 반씩 잘라야 해서
                // 규약이 복잡해지고, 터미널의 `NativeMetalCell.width`도 같은 방식(폭을 셀이 든다)이다.
                try cells.append(allocator, .{
                    .rect = .{
                        @floatFromInt(12 + col * cell_w),
                        @floatFromInt(12 + row * cell_h),
                        @floatFromInt(cell_w * slot.w_cells),
                        @floatFromInt(cell_h),
                    },
                    .uv = d3d11_cells.uvFromAtlasRect(slot.x_px, 0, cell_w * slot.w_cells, cell_h, atlas_w, atlas_h),
                    .fg = fg,
                    .bg = bg_none,
                });
                col += w;
            }
        }

        try present.beginFrame(clear);
        try pipeline.draw(cells.items, present.width_px, present.height_px);
        try present.present(false);
        frames += 1;
        _ = usleep(8_000);
    }
    if (close_requested) window.requestClose();

    try stdout.writeAll("maru.dwrite-text-smoke.v1\n");
    try stdout.print("font_family={s}\n", .{raster.family});
    // **시도한 수와 열린 수는 다르다** — 폴백 티어에 이름을 넣어도 그 폰트가 없으면 열리지 않는다.
    try stdout.print("fallback_faces_opened={d}\n", .{raster.fallback_opened});
    try stdout.print("em_size_px={d:.1}\n", .{raster.em_size_px});
    try stdout.print("cell_px={d}x{d} baseline={d}\n", .{ cell_w, cell_h, raster.metrics.baseline_px });
    // 셀이 **왜** 그 크기인지 설명하는 근거. 이 값 없이는 유도 규칙의 테스트가 무엇을 흉내 내는지 알 수 없다.
    try stdout.print("design_units upem={d} ascent={d} descent={d} line_gap={d} advance={d}\n", .{
        raster.design.upem,
        raster.design.ascent,
        raster.design.descent,
        raster.design.line_gap,
        raster.design.advance_width,
    });
    try stdout.print("atlas_px={d}x{d} slots={d}\n", .{ atlas_w, atlas_h, slots });
    // **셋을 갈라 센다.** 합쳐 세면 폰트 경로가 죽어도 합성 글리프가 수를 채워 성공처럼 보인다.
    try stdout.print("slots_from_font={d} slots_synthesized={d} slots_blank={d}\n", .{ font_slots, synth_slots, blank_slots });
    try stdout.print("atlas_covered_pixels={d}\n", .{covered_total});
    try stdout.print("cells_drawn={d}\n", .{cells.items.len});
    try stdout.print("frames_presented={d}\n", .{frames});
    try stdout.print("driver={s}\n", .{@tagName(present.driver)});
    try stdout.writeAll("visible UI: text uses DirectWrite; borders and blocks use synthesized glyphs. The real terminal screen is W7.2c.\n");
    try stdout.flush();
    // **성공 경로에서도 stderr를 비운다.** 위 래스터화 경고가 버퍼에 남아 있으면 조용히 사라진다 —
    // 실측으로 겪었다: 진단을 넣었는데 화면에 아무것도 안 나와 원인을 한참 찾았다.
    try stderr.flush();
}

/// `maru win32-frame-smoke` — W7.2c-1. **actual PTY 출력이 Windows 셰이퍼·DirectWrite 래스터라이저를 지나
/// 중립 `RenderFrame`이 되는지**를 창 없이 확인한다.
///
/// 창을 띄우지 않는 이유가 있다. 계약 §2a가 걸어 둔 질문은 "중립 렌더러 계약이 Metal 한 구현에만 맞춰져
/// 있지 않은가"이고, 그 답은 **그림이 아니라 계약이 받아들이는가**로 나온다. 여기서 프레임이 서면 그
/// 답이 예다 — 화면에 올리는 것은 W7.2c-2다.
///
/// 판정은 **셋을 갈라 세는 것**이다(`win32_terminal.FrameCounts`): 잉크 있는 글리프 수, actual로 올린
/// 슬롯이 덮은 픽셀 수, 그리고 폴백·빈칸 수. 슬롯 수만 세면 글자가 하나도 안 그려져도 성공처럼 보인다 —
/// W7.2b·W7.3에서 같은 함정을 두 번 겪었다.
fn runWin32FrameSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-frame-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    // ── 폰트 ───────────────────────────────────────────────────────────────────────────────
    var raster = dwrite_font.Rasterizer.create(allocator, "", "", 18.0) catch |err| {
        try stderr.print("maru win32-frame-smoke: could not set up the font({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(dwrite_font.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer raster.destroy();

    // 두 칸 글자(한글·CJK)가 두 칸 폭 슬롯을 받으므로 스크래치는 그 폭에 맞춘다.
    const scratch = try allocator.alloc(u8, win32_text.NeutralRasterizer.scratchSizeFor(raster.metrics.width_px * 2, raster.metrics.height_px));
    defer allocator.free(scratch);

    const builder = win32_terminal.FrameBuilder{
        .shaper = .{ .raster = raster },
        .rasterizer = .{ .raster = raster, .scratch = scratch },
    };

    // ── actual PTY와 중립 프레임 루프 ────────────────────────────────────────────────────────
    // 설정 순서는 `app/pty_loop_smoke.zig`와 같다 — 그쪽이 이 계약의 단일 출처이고, 여기서 다르게
    // 조립하면 두 경로가 갈린다.
    const size: maru.terminal.Size = .{ .cols = 80, .rows = 24 };
    // 각본은 `app/fixture_script.zig`가 단일 출처다(셸마다 다르다). 셸 선택은 §3.1a의 티어가 한다.
    const script = maru.app.fixture_script.interactiveEcho(@import("builtin").os.tag);
    const command = maru.pty.resolveInteractiveShell();

    var live: maru.app.LivePtySession = undefined;
    try live.init(io, allocator, 10, .{ .command = command, .args = script.args, .size = size }, 16);
    defer live.deinit();

    var surfaces = [_]maru.session.surface.Surface{try maru.session.surface.Surface.init(allocator, 1, size)};
    defer surfaces[0].deinit();
    surfaces[0].title = "win32 frame smoke";
    surfaces[0].command = command;

    var tab_ptrs = [_]*maru.session.surface.Surface{&surfaces[0]};
    var app_window: maru.session.window.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = maru.app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try live.attachSurface(&runtime, &surfaces[0], true);

    var pump = live.pump(&runtime);
    var renderer_state = maru.renderer.RendererState.init(allocator, .{});
    defer renderer_state.deinit();
    var loop = maru.app.AppFrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state, io);

    // 셸이 프롬프트를 낼 시간을 준 뒤, 눈에 보이는 글자를 만들 명령을 보낸다.
    _ = usleep(400_000);
    // 스크립트 바이트는 키 이벤트 경로가 아니라 입력 경로로 보낸다 — `handleKeyEvent`는 키바인딩 판정용이다.
    try maru.app.host.sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = script.input });

    var counts: win32_terminal.FrameCounts = .{};
    var frames: usize = 0;
    var ended = false;
    while (frames < 60 and !ended) : (frames += 1) {
        var tick = try loop.tickWithFrameBuilder(builder);
        defer tick.deinit(allocator);
        counts.add(tick.frame.render_frame);
        ended = tick.ended();
        _ = usleep(16_000);
    }

    try stdout.writeAll("maru.win32-frame-smoke.v1\n");
    try stdout.print("font_family={s}\n", .{raster.family});
    try stdout.print("cell_px={d}x{d}\n", .{ raster.metrics.width_px, raster.metrics.height_px });
    try stdout.print("frames_built={d}\n", .{frames});
    try stdout.print("glyph_quads={d}\n", .{counts.glyph_quads});
    try stdout.print("atlas_uploads={d}\n", .{counts.uploads});
    // **이 줄이 판정이다.** 슬롯을 올렸는데 덮인 픽셀이 0이면 글자가 하나도 안 그려진 것이다.
    try stdout.print("upload_non_clear_pixels={d}\n", .{counts.non_clear_pixels});
    try stdout.print("fallback_glyphs={d}\n", .{counts.fallback});
    try stdout.print("replacement_glyphs={d}\n", .{counts.replacement});
    try stdout.print("raster_skipped={d}\n", .{counts.skipped});
    try stdout.print("atlas_entries={d}\n", .{renderer_state.atlas.entryCount()});
    try stdout.writeAll("visible UI: none — this is a neutral contract smoke. Putting it on screen is W7.2c-2.\n");
    try stdout.flush();
    try stderr.flush();
}

/// 붙여넣기 한 번의 결과. **갈래별로 센다** — 합치면 "막혔는데 붙은 줄 알았다"를 못 가른다.
const PasteOutcome = struct {
    pastes: usize = 0,
    paste_bytes: usize = 0,
    bracketed: usize = 0,
    blocked: usize = 0,
    errors: usize = 0,
};

/// 클립보드를 읽어 활성 표면에 붙여넣는다 — W7.4b 의 규칙 그대로다.
///
/// **화음(`Ctrl+Shift+V`)과 우클릭이 이 함수를 공유한다.** 두 자리에 같은 규칙을 복사하면 한쪽만 고쳐져
/// 어긋난다 — 그리고 그 규칙이 하필 **보안 규칙**이다(raw 바이트를 셸에 보내지 않는다: bracketed 래핑·
/// 개행 정규화·ESC 치환. 클립보드의 `\x1b[201~` 이 래핑을 빠져나오면 명령이 실행된다).
fn pasteClipboardIntoActive(
    allocator: std.mem.Allocator,
    io: std.Io,
    hwnd: ?*anyopaque,
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    stderr: *std.Io.Writer,
    paste_protection: bool,
    bracketed_paste_is_safe: bool,
    out: *PasteOutcome,
) !void {
    const maybe = win32_clipboard.read(allocator, hwnd) catch |err| {
        try stderr.print("  warning: clipboard read failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
        out.errors += 1;
        return;
    };
    const text = maybe orelse return;
    defer allocator.free(text);

    var needs_confirm = false;
    var bracketed = false;
    if (app_window.active()) |active| {
        // 판정과 bracketed 읽기만 락 안에서 — 인코딩(할당·복사)은 밖에서 한다(macOS `submitPaste` 순서).
        active.lockCore(io);
        needs_confirm = active.core.pasteNeedsConfirmation(text, paste_protection, bracketed_paste_is_safe);
        bracketed = active.core.bracketedPasteEnabled();
        active.unlockCore(io);
    }
    if (needs_confirm) {
        // **확인 모달이 없으면 붙여넣지 않는다.** 모달이 없다고 보호를 건너뛰면 위험한 붙여넣기가
        // 조용히 실행된다 — 거절하고 세는 편이 맞다(확인 UI 는 W8).
        try stderr.writeAll("  paste held: the content is risky (the confirm UI is W8). Nothing was pasted\n");
        out.blocked += 1;
        return;
    }
    const encoded = maru.terminal.encodePasteWith(bracketed, allocator, text) catch |err| {
        try stderr.print("  warning: paste encoding failed({s})\n", .{@errorName(err)});
        out.errors += 1;
        return;
    };
    defer allocator.free(encoded);
    maru.app.host.sendInputToActiveSurface(app_window, runtime, .{ .bytes = encoded }) catch |err| {
        try stderr.print("  warning: paste send failed({s})\n", .{@errorName(err)});
        out.errors += 1;
        return;
    };
    out.pastes += 1;
    out.paste_bytes += encoded.len;
    if (bracketed) out.bracketed += 1;
}

/// `maru win32-clipboard-smoke` — W7.4b. **OS 클립보드를 actual로 왕복시킨다.**
///
/// 순수 변환(`utf16ForClipboard`·`utf8ForTerminal`)은 모든 타깃에서 테스트가 돌지만, `GlobalAlloc`
/// 소유권과 NUL 종단 규약은 **actual Win32 만이 판정한다** — 그 둘이 이 파일에서 제일 틀리기 쉬운 자리다
/// (성공한 `SetClipboardData` 뒤에 `GlobalFree` 를 부르면 다른 앱이 해제된 메모리를 읽고, `GlobalSize` 로
/// 길이를 재면 뒤쪽 쓰레기가 붙는다). 그래서 키보드를 끼지 않고 쓰기→읽기만 재는 스모크를 따로 둔다:
/// 붙여넣기 화음은 합성 메시지로 모디파이어를 실을 수 없어(`GetKeyState` 가 큐 상태를 안 본다) 창을
/// 띄우는 스모크로는 이 경로가 영원히 미측정으로 남는다.
fn runWin32ClipboardSmoke(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    arg: ?[]const u8,
) !void {
    const paste_encode_mode = arg != null and std.mem.eql(u8, arg.?, "--paste-encode");
    const expect_foreign: ?[]const u8 = if (paste_encode_mode) null else arg;
    if (builtin.os.tag != .windows) {
        try stderr.writeAll("maru win32-clipboard-smoke: Windows only\n");
        try stderr.flush();
        return error.UnsupportedPlatform;
    }

    try stdout.writeAll("maru.win32-clipboard-smoke.v1\n");

    // **다른 앱이 넣은 것을 읽는 모드.** 우리가 쓰고 우리가 읽으면 `GlobalAlloc` 이 요청한 크기를 정확히
    // 돌려주므로 NUL 종단 규약이 지켜지는지 판정되지 않는다 — 길이를 `GlobalSize` 로 재도 같은 답이 나온다
    // (대조군으로 확인했다). 붙여넣기는 **남이 쓴 것을 읽는 일**이고, 그 할당은 패딩될 수 있다.
    // 그래서 외부 작성자가 넣은 값을 expected값과 맞춰 보는 모드를 따로 둔다.
    if (expect_foreign) |want| {
        const got = win32_clipboard.read(allocator, null) catch |err| {
            try stderr.print("foreign: read failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
            try stderr.flush();
            return error.ClipboardRoundtripFailed;
        };
        if (got) |text| {
            defer allocator.free(text);
            const ok = std.mem.eql(u8, text, want);
            try stdout.print("foreign_read_bytes={d} expect_bytes={d} match={}\n", .{ text.len, want.len, ok });
            if (!ok) {
                try stderr.print("foreign: expected \"{f}\" actual \"{f}\"\n", .{
                    std.zig.fmtString(want),
                    std.zig.fmtString(text),
                });
            }
            try stdout.flush();
            try stderr.flush();
            if (!ok) return error.ClipboardRoundtripFailed;
            return;
        }
        try stdout.writeAll("foreign_read_bytes=0 match=false\n");
        try stdout.flush();
        try stderr.flush();
        return error.ClipboardRoundtripFailed;
    }

    // **지금 클립보드에 있는 것을 붙여넣기 규칙에 태워 본다.** 붙여넣기 화음은 합성 메시지로 누를 수
    // 없어(모디파이어가 안 실린다) 창 쪽 경로가 미측정으로 남는데, 그 경로에서 정작 중요한 것은 "raw
    // 바이트가 아니라 `encodePasteWith` 를 거친 바이트가 셸에 간다"는 것이다. 그 규칙만 떼어 잰다.
    if (paste_encode_mode) {
        const text = (win32_clipboard.read(allocator, null) catch |err| {
            try stderr.print("paste-encode: read failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
            try stderr.flush();
            return error.ClipboardRoundtripFailed;
        }) orelse {
            try stdout.writeAll("paste_encode: the clipboard is empty\n");
            try stdout.flush();
            return error.ClipboardRoundtripFailed;
        };
        defer allocator.free(text);

        for ([_]bool{ false, true }) |bracketed| {
            const encoded = try maru.terminal.encodePasteWith(bracketed, allocator, text);
            defer allocator.free(encoded);
            // ESC 가 본문에 살아 있으면 `\x1b[201~` 로 래핑을 빠져나올 수 있다 — 그것이 이 규칙의 요점이다.
            const has_esc = std.mem.indexOfScalar(u8, encoded, 0x1B) != null;
            const body = if (bracketed and encoded.len >= 12) encoded[6 .. encoded.len - 6] else encoded;
            const body_has_esc = std.mem.indexOfScalar(u8, body, 0x1B) != null;
            const wrapped = std.mem.startsWith(u8, encoded, "\x1b[200~") and std.mem.endsWith(u8, encoded, "\x1b[201~");
            try stdout.print(
                "paste_encode bracketed={} raw_bytes={d} encoded_bytes={d} wrapped={} body_has_esc={} any_esc={}\n",
                .{ bracketed, text.len, encoded.len, wrapped, body_has_esc, has_esc },
            );
        }
        // 보호 게이트는 코어 상태(bracketed)와 설정만 보는 순수 판정이라 창 없이도 잰다.
        for ([_]bool{ false, true }) |bracketed| {
            const needs = maru.terminal.pasteNeedsConfirmationWith(bracketed, text, true, true);
            try stdout.print("paste_needs_confirm bracketed={} needs={}\n", .{ bracketed, needs });
        }
        try stdout.flush();
        try stderr.flush();
        return;
    }

    // 한글·이모지·CRLF·CR단독을 한 번에 태운다 — `CF_TEXT`(ANSI 949)로 샜다면 한글에서 깨지고,
    // 줄바꿈 규칙이 틀렸다면 왕복 결과가 원본과 달라진다.
    const cases = [_]struct { name: []const u8, input: []const u8, want_back: []const u8 }{
        .{ .name = "ascii", .input = "hello", .want_back = "hello" },
        .{ .name = "hangul", .input = "clipboard sample", .want_back = "clipboard sample" },
        .{ .name = "emoji", .input = "tab \u{1F389} ok", .want_back = "tab \u{1F389} ok" },
        // 쓸 때 LF→CRLF, 읽을 때 CRLF→CR. **왕복이 항등이 아니다** — 그게 맞는 동작이다:
        // Windows 앱에는 CRLF 를 주고, 셸에는 CR 하나를 준다(CRLF 를 주면 두 줄이 실행된다).
        .{ .name = "newline", .input = "echo a\necho b", .want_back = "echo a\recho b" },
        .{ .name = "already-crlf", .input = "a\r\nb", .want_back = "a\rb" },
    };

    var passed: usize = 0;
    var failed: usize = 0;
    var errors: usize = 0;

    for (cases) |case| {
        win32_clipboard.write(allocator, null, case.input) catch |err| {
            try stderr.print("  {s}: write failed({s}, Win32 error {d})\n", .{ case.name, @errorName(err), win32_clipboard.last_error });
            errors += 1;
            continue;
        };
        const got = win32_clipboard.read(allocator, null) catch |err| {
            try stderr.print("  {s}: read failed({s}, Win32 error {d})\n", .{ case.name, @errorName(err), win32_clipboard.last_error });
            errors += 1;
            continue;
        };
        if (got) |text| {
            defer allocator.free(text);
            if (std.mem.eql(u8, text, case.want_back)) {
                passed += 1;
            } else {
                failed += 1;
                try stderr.print("  {s}: expected \"{f}\" actual \"{f}\"\n", .{
                    case.name,
                    std.zig.fmtString(case.want_back),
                    std.zig.fmtString(text),
                });
            }
        } else {
            // 방금 썼는데 텍스트가 없다 = `SetClipboardData` 가 성공했다고 거짓말했거나 소유권 규칙이 깨졌다.
            failed += 1;
            try stderr.print("  {s}: wrote it just now but reading gives null\n", .{case.name});
        }
    }

    // 큰 입력 — NUL 상한과 부분 복사 경계를 밟는다.
    const big = try allocator.alloc(u8, 300 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');
    var big_roundtrip: usize = 0;
    if (win32_clipboard.write(allocator, null, big)) |_| {
        if (win32_clipboard.read(allocator, null) catch null) |text| {
            defer allocator.free(text);
            big_roundtrip = text.len;
        }
    } else |err| {
        try stderr.print("  big: write failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
        errors += 1;
    }

    try stdout.print("cases={d} passed={d} failed={d} errors={d}\n", .{ cases.len, passed, failed, errors });
    // **이 줄이 판정이다.** 300 KiB 를 넣고 그대로 돌아오지 않으면 길이 계산이 틀렸다.
    try stdout.print("big_input={d} big_roundtrip={d}\n", .{ big.len, big_roundtrip });
    try stdout.flush();
    try stderr.flush();
    if (failed > 0 or errors > 0) return error.ClipboardRoundtripFailed;
}

/// `maru win32-file-tree-smoke` — W8.2. **중립 파일 트리가 Windows 에서 실제 디렉터리를 훑는다.**
///
/// W8.1 이 백엔드 한 겹(루트 검증·리프 열기)을 열었고, 여기서는 그 위의 **중립 로직 전체**를 돌린다:
/// 루트 등록 → 백엔드 스캔 → `applySnapshotWithIdentity` → `buildRows`. 즉 파일 패널이 화면에 붙기
/// 전에 **데이터가 끝까지 흐르는지**를 먼저 본다(§2a 가 프레임으로 물었던 것과 같은 순서 — 그림보다
/// 계약이 먼저다).
///
/// **판정은 행 수가 아니라 내용이다.** 행이 몇 개인지만 세면 스캔이 빈 결과를 내도 "성공" 처럼 보인다
/// (이 저장소가 여러 번 밟은 부류). 그래서 만든 fixture 의 이름들이 실제로 행에 있는지를 본다.
///
/// 스캔은 백엔드의 워커 스레드가 돌리므로 `takeResult` 를 폴링한다 — 상한 안에 안 오면 **실패**다(행은
/// CI 에서 실패보다 나쁘다, §4 의 같은 규율).
fn runWin32FileTreeSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-file-tree-smoke: Windows only\n");
        return error.UnsupportedPlatform;
    }

    // ── fixture ─────────────────────────────────────────────────────────────────────────────
    // 실제 디렉터리를 만든다. 이름을 **비-ASCII 하나** 섞는다 — 백엔드가 WTF-8 경로를 끝까지 나르는지가
    // 이 슬라이스의 숨은 판정이고, 그것이 깨지면 한글 사용자 이름에서 파일 패널이 통째로 빈다.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_native = cwd_buf[0..try std.Io.Dir.cwd().realPath(io, &cwd_buf)];
    const base = try maru.path_shape.normalizeSeparators(allocator, base_native);
    defer allocator.free(base);
    const root_path = try std.fmt.allocPrint(allocator, "{s}/zig-out/maru-file-tree-smoke", .{base});
    defer allocator.free(root_path);

    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, root_path) catch {};
    try cwd.createDirPath(io, root_path);
    const sub = try std.fmt.allocPrint(allocator, "{s}/sub", .{root_path});
    defer allocator.free(sub);
    try cwd.createDirPath(io, sub);
    for ([_][]const u8{ "alpha.txt", "beta.md", "\u{d55c}\u{ae00}.txt" }) |name| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_path, name });
        defer allocator.free(p);
        try cwd.writeFile(io, .{ .sub_path = p, .data = "x" });
    }

    // ── 중립 트리 + 백엔드 ───────────────────────────────────────────────────────────────────
    var tree = maru.session.file_tree.Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{root_path});

    var backend = try file_tree_backend.Backend.init(allocator, io);
    defer backend.deinit();

    // **제품 흐름을 그대로 밟는다.** `file_panel.zig` 는 루트를 세울 때 먼저 검증하고, 그때 열린
    // **no-follow 디렉터리 능력을 첫 스캔에 넘긴다**(`submitValidatedRootScan`). 처음엔 평범한
    // `submit` 으로 짰는데, 그것은 하위 디렉터리를 펼칠 때 쓰는 **다른 길**이라 W8.1 이 고친 자리를
    // 하나도 안 밟았다 — 두 수정을 되돌려도 스모크가 통과했다(적대적 검증이 잡았다).
    var validated = (try file_tree_backend.validateRootSnapshot(allocator, io, root_path)) orelse {
        try stderr.writeAll("maru win32-file-tree-smoke: root validation failed\n");
        return error.RootValidationFailed;
    };
    var validated_owned = true;
    defer if (validated_owned) validated.deinit(allocator, io);
    const validated_dir = validated.dir orelse {
        try stderr.writeAll("maru win32-file-tree-smoke: root validation returned no directory\n");
        return error.RootValidationFailed;
    };
    validated.dir = null; // 첫 스캔이 이 능력을 가져간다.

    const owned = try allocator.dupe(u8, root_path);
    if (!backend.submitValidatedRootScan(owned, 0, validated_dir)) {
        allocator.free(owned);
        validated_dir.close(io);
        try stderr.writeAll("maru win32-file-tree-smoke: could not submit the validated root scan\n");
        return error.ScanSubmitFailed;
    }
    validated.deinit(allocator, io);
    validated_owned = false;

    // **상한을 실제로 강제한다.** 결과가 안 오면 행이 아니라 실패다.
    var rounds: usize = 0;
    var scanned = false;
    var entry_count: usize = 0;
    var sub_scanned = false;
    while (rounds < 4000) : (rounds += 1) {
        if (backend.takeResult()) |taken| {
            var result = taken;
            defer result.deinit(allocator, io);
            if (!result.ok) {
                try stderr.print("maru win32-file-tree-smoke: scan failed for {s}\n", .{result.path});
                return error.ScanFailed;
            }
            var inputs: std.ArrayList(maru.session.file_tree.EntryInput) = .empty;
            defer inputs.deinit(allocator);
            for (result.entries.items) |e| try inputs.append(allocator, .{ .name = e.name, .kind = e.kind, .identity = e.identity });
            try tree.applySnapshotWithIdentity(result.path, result.identity, inputs.items);
            if (!scanned) {
                entry_count = result.entries.items.len;
                scanned = true;
                // **하위 디렉터리는 평범한 `submit` 으로 펼친다** — 제품이 그렇게 한다(두 번째 길).
                const sub_owned = try allocator.dupe(u8, sub);
                if (!backend.submit(sub_owned, 0)) {
                    allocator.free(sub_owned);
                    try stderr.writeAll("maru win32-file-tree-smoke: could not submit the child scan\n");
                    return error.ScanSubmitFailed;
                }
            } else {
                sub_scanned = true;
                break;
            }
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    if (!scanned or !sub_scanned) {
        try stderr.writeAll("maru win32-file-tree-smoke: the scan did not finish in time\n");
        return error.ScanTimeout;
    }

    // ── 행을 만든다 ──────────────────────────────────────────────────────────────────────────
    var rows: std.ArrayList(maru.session.file_tree.Row) = .empty;
    defer rows.deinit(allocator);
    try tree.buildRows(allocator, &.{.{ .path = root_path, .active = true }}, &rows);

    // ── 판정: 이름이 실제로 행에 있는가 ──────────────────────────────────────────────────────
    var found_alpha = false;
    var found_beta = false;
    var found_hangul = false;
    var found_sub = false;
    var dirs: usize = 0;
    var files: usize = 0;
    for (rows.items) |row| {
        switch (row) {
            .directory => |d| {
                dirs += 1;
                if (std.mem.eql(u8, d.label, "sub")) found_sub = true;
            },
            .file => |f| {
                files += 1;
                if (std.mem.eql(u8, f.label, "alpha.txt")) found_alpha = true;
                if (std.mem.eql(u8, f.label, "beta.md")) found_beta = true;
                if (std.mem.eql(u8, f.label, "\u{d55c}\u{ae00}.txt")) found_hangul = true;
            },
            else => {},
        }
    }

    try stdout.print("maru.win32-file-tree-smoke.v1\n", .{});
    try stdout.print("root={s}\n", .{root_path});
    try stdout.print("scan_entries={d} rows={d} dirs={d} files={d}\n", .{ entry_count, rows.items.len, dirs, files });
    try stdout.print("found: alpha={} beta={} hangul={} sub={}\n", .{ found_alpha, found_beta, found_hangul, found_sub });
    try stdout.flush();

    // **내용으로 판정한다** — 행 수만 보면 빈 스캔도 성공처럼 보인다.
    if (!(found_alpha and found_beta and found_hangul and found_sub)) {
        try stderr.writeAll("maru win32-file-tree-smoke: fixture names are missing from the rows\n");
        return error.RowsMissing;
    }
    try stderr.flush();
}

/// `maru win32-file-tree-draw-smoke` — W8.2 ⒝. **파일 트리가 Windows 화면에 실제로 뜬다.**
///
/// ⒜ 는 데이터가 행까지 흐르는 것을 텍스트로 봤다. 이것은 그 행을 **픽셀까지** 내린다.
///
/// **이 슬라이스가 작은 이유**는 적대적 검증이 찾아냈다. §2m.4 에 "Windows 에는 `ChromeDraw` 를 낮추는
/// 층이 없다" 고 적었는데, 탐색기 행의 **텍스트 투영은 이미 중립**이었다 —
/// `cell_text.buildFileTreeDrawList` 가 이름과 달리 CoreText 를 한 번도 안 부르고
/// `renderer.DrawList` 를 낸다. 실측 순서: 그 함수 본문에 `coretext_*` 참조 0 회 → OS 가드 없음 →
/// Windows 로 컴파일·링크됨(해시 확인) → **런타임에 실제로 글자가 나온다**(`"vproj>src README.md"`).
/// 앞의 셋만으로는 부족하다는 것을 이 저장소가 두 번 밟았다(`system_text` 는 컴파일되지만
/// `builtin.os.tag != .macos` 에서 곧장 에러다).
///
/// 그래서 남은 것은 그 DrawList 를 Windows 가 이미 가진 셀 파이프라인에 먹이는 일뿐이다. 터미널이 밟는
/// 길과 **정확히 같은 네 단계**를 쓴다: `buildFrameFromDrawListWithRasterizer` → 아틀라스 부분 업로드 →
/// `buildNativeCellsFromGlyphQuads` → `cellFromNative` → `pipeline.draw`. 다른 길을 내면 한쪽만
/// 고쳐지는 순간 조용히 갈린다(`win32_terminal.zig` 머리말이 경고하는 것).
///
/// **아직 배경 띠(hover·선택·활성)는 없다.** 그것은 쿼드라서 D3D11 에 두 번째 파이프라인이 필요하고
/// (`d3d11_cells` 가 "둘이 되는 시점(chrome quad·kitty 이미지)" 으로 예고해 둔 자리다) 이 슬라이스
/// 밖이다. 글자가 먼저 뜨는 것이 순서다 — 띠만 있고 글자가 없으면 아무것도 못 읽는다.
fn runWin32FileTreeDrawSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-file-tree-draw-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    var loaded = try maru.config.loader.loadDefault(io, allocator);
    defer loaded.deinit();
    const cfg = loaded.config;

    // **창·스왑체인·아틀라스·표현은 공용 호스트가 세운다**(`win32_draw_host`). 표면마다 이 절차를
    // 복사하면 한쪽만 고쳐지는 순간 조용히 갈린다 — 그 규율의 근거는 그 파일 머리말에 있다.
    var host = draw_host.Host.open(allocator, cfg, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W8.2 file tree)"),
    }) catch {
        try draw_host.reportSetupFailure(stderr, "win32-file-tree-draw-smoke");
        return error.UnknownCommand;
    };
    defer host.close();
    const cell_w = host.cell_w;
    const cell_h = host.cell_h;

    // ── 진짜 디렉터리를 훑는다 ───────────────────────────────────────────────────────────────
    //
    // fixture 를 만들지 않고 **저장소 자신**을 연다. 화면에 뜨는 것이 진짜 파일 이름이라야 "그럴듯한
    // 그림" 과 "실제로 도는 것" 이 구별된다.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_native = root_buf[0..try std.Io.Dir.cwd().realPath(io, &root_buf)];
    const root_path = try maru.path_shape.normalizeSeparators(allocator, root_native);
    defer allocator.free(root_path);

    var tree = maru.session.file_tree.Tree.init(allocator);
    defer tree.deinit();
    try tree.replaceExplicitRoots(&.{root_path});

    var backend = try file_tree_backend.Backend.init(allocator, io);
    defer backend.deinit();

    var validated = (try file_tree_backend.validateRootSnapshot(allocator, io, root_path)) orelse {
        try stderr.writeAll("maru win32-file-tree-draw-smoke: root validation failed\n");
        return error.RootValidationFailed;
    };
    var validated_owned = true;
    defer if (validated_owned) validated.deinit(allocator, io);
    const validated_dir = validated.dir orelse {
        try stderr.writeAll("maru win32-file-tree-draw-smoke: root validation returned no directory\n");
        return error.RootValidationFailed;
    };
    validated.dir = null;

    const owned = try allocator.dupe(u8, root_path);
    if (!backend.submitValidatedRootScan(owned, 0, validated_dir)) {
        allocator.free(owned);
        validated_dir.close(io);
        try stderr.writeAll("maru win32-file-tree-draw-smoke: could not submit the validated root scan\n");
        return error.ScanSubmitFailed;
    }
    validated.deinit(allocator, io);
    validated_owned = false;

    var rounds: usize = 0;
    var scanned = false;
    while (rounds < 4000 and !scanned) : (rounds += 1) {
        if (backend.takeResult()) |taken| {
            var result = taken;
            defer result.deinit(allocator, io);
            if (!result.ok) {
                try stderr.print("maru win32-file-tree-draw-smoke: scan failed for {s}\n", .{result.path});
                return error.ScanFailed;
            }
            var inputs: std.ArrayList(maru.session.file_tree.EntryInput) = .empty;
            defer inputs.deinit(allocator);
            for (result.entries.items) |e| try inputs.append(allocator, .{ .name = e.name, .kind = e.kind, .identity = e.identity });
            try tree.applySnapshotWithIdentity(result.path, result.identity, inputs.items);
            scanned = true;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    if (!scanned) {
        try stderr.writeAll("maru win32-file-tree-draw-smoke: the scan did not finish in time\n");
        return error.ScanTimeout;
    }

    var rows: std.ArrayList(maru.session.file_tree.Row) = .empty;
    defer rows.deinit(allocator);
    try tree.buildRows(allocator, &.{.{ .path = root_path, .active = true }}, &rows);

    // ── 행 → DrawList ────────────────────────────────────────────────────────────────────────
    const grid = host.grid();
    // **창을 넘겨 그리지 않는다.** 스크롤이 0 이라 앞에서부터 창 높이만큼이다 —
    // `session/file_tree_layout.drawWindow` 가 세는 것과 같은 규율의 특수한 경우다.
    const visible: u16 = @intCast(@min(rows.items.len, grid.rows));
    const fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 } };
    const active_fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };

    // **선택 계약을 실제로 태운다.** `FileTreeSelectionPaint` 는 **전경만** 나르고 배경은 렌더가
    // 그린다는 계약이다(그 doc: "the background renderer resolves the same transient selection
    // index"). 그 둘이 **같은 인덱스**를 봐야 글자와 띠가 어긋나지 않으므로, 여기서 한 번 정해
    // 양쪽에 넘긴다 — 두 번 계산하면 그 순간 갈린다.
    //
    // 스모크에는 사용자 조작이 없으니 인덱스를 정해 둔다. 행이 모자라면 선택이 없다.
    const selected_row: ?usize = if (visible > 3) 3 else null;
    const selection_fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    const draw_list = try cell_text.buildFileTreeDrawList(
        allocator,
        rows.items,
        null,
        0,
        visible,
        grid.cols,
        fg,
        active_fg,
        if (selected_row) |index| .{ .index = index, .foreground = selection_fg } else null,
        null,
        null,
    );

    // ── DrawList → 화면 ──────────────────────────────────────────────────────────────────────
    // **DrawList 소유권은 프레임으로 넘어간다.** `RenderFrame.deinit` 이 `self.draw_list.deinit` 을
    // 부르므로 여기서 또 `defer draw_list.deinit` 을 걸면 **double free** 다. 적대적 검증이 잡았고,
    // 그때까지 안 보였던 이유가 중요하다 — 앞선 실행들은 스크린샷을 찍고 **프로세스를 죽였기** 때문에
    // teardown 이 한 번도 안 돌았다. 빈 디렉터리(행 2 개)가 900 프레임을 빨리 지나 거기까지 갔다.
    // 실패 경로에서는 아직 프레임이 없으니 우리가 해제한다.
    const prepared = try host.prepare(allocator, draw_list);
    var frame = prepared.frame;
    defer frame.deinit(allocator);
    const region_uploads = prepared.region_uploads;

    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 },
        .default_bg = .{ .r = 0x1E, .g = 0x24, .b = 0x30 },
    };

    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer cells.deinit(allocator);
    // ── 선택 띠 ──────────────────────────────────────────────────────────────────────────────
    //
    // **행 띠에는 새 쿼드 파이프라인이 필요 없었다.** `d3d11_cells` 가 "둘이 되는 시점(chrome quad·
    // kitty 이미지)" 으로 예고해 둔 자리를 여기서 밟을 줄 알았는데, 실험해 보니 **띠는 곧 "배경이 있는
    // 셀"** 이라 기존 파이프라인이 그대로 그린다(`Cell.bg` — 그 doc: "알파가 판정이다"). 쿼드가
    // 필요한 것은 **셀 격자에 안 맞는 것**(둥근 모서리·부분 테두리·셀 사이에 걸친 선)이지 행 띠가 아니다.
    //
    // **글리프보다 먼저 넣는다** — 뒤에 넣었더니 그 행 글자를 통째로 덮었다(실측). 그리는 순서가 곧
    // z 순서다.
    var band_cells: usize = 0;
    if (selected_row) |band_row| {
        var c: u32 = 0;
        while (c < grid.cols) : (c += 1) {
            // **`solidCell` 이 이 모양의 단일 출처다.** 손으로 쓰면 `uv` 표식이 갈린다 — 실제로
            // 갈렸다: 여기 `uv = {0,0,0,0}` 은 아틀라스 (0,0) 을 읽어서 **첫 글리프의 좌상단 픽셀
            // 알파**가 띠에 섞여 들고 있었다(§2m.22).
            try cells.append(allocator, d3d11_cells.solidCell(
                @floatFromInt(c * cell_w),
                @floatFromInt(@as(u32, @intCast(band_row)) * cell_h),
                @floatFromInt(cell_w),
                @floatFromInt(cell_h),
                d3d11_cells.colorFromArgb(0xFF3A5FCD),
                .{ 0, 0, 0, 0 },
            ));
            band_cells += 1;
        }
    }
    // **글리프는 띠 뒤에 잇는다** — 위 doc 의 z 순서 규율. 호스트가 아틀라스 크기를 알고 있으므로
    // `cellFromNative` 에 넘길 값이 어긋날 자리가 없다.
    _ = try host.appendGlyphCells(allocator, frame, colors, &cells);

    // **프레임 수에 근거를 둔다.** 처음엔 900 이었는데 실측 **27 초**였다 — ⒜ 스모크가 67 ms 인 것에
    // 견주면 400 배다. build step 은 반복해서 도는데 그때마다 창이 27 초를 차지한다(적대적 검증이 잡았다).
    //
    // **판정은 루프 전에 이미 끝나 있다** — 행·라벨·프레임 준비는 한 번 재고, 루프가 더하는 것은
    // "반복 표현과 크기 변경이 견디는가" 뿐이다. 그 둘에는 120 프레임(약 3.5 초)이면 족하고, 스크린샷을
    // 잡기에도 충분하다(캡처가 200 ms 마다 창을 찾는다).
    const frames = try host.presentLoop(cells.items, 0xFF1E2430, 120);

    // **판정은 글리프 수가 아니라 내용이다.** `prepared()` 는 "글리프가 잡혔고 아틀라스가 찼다" 까지만
    // 본다 — 엉뚱한 행을 그려도, 라벨이 통째로 비어도 참이다. ⒜ 가 "행 수가 아니라 이름을 본다" 로
    // 못 박은 것과 같은 자리인데 이 스모크가 그것을 어겼다(적대적 검증이 잡았다).
    //
    // 그려진 셀에서 글자를 도로 읽어 **각 행의 라벨이 그 줄에 실제로 있는지** 확인한다. 디렉터리가
    // 무엇이든 성립하는 판정이라 fixture 에 안 묶인다.
    var labels_checked: usize = 0;
    var labels_matched: usize = 0;
    {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        var row_index: u16 = 0;
        while (row_index < visible) : (row_index += 1) {
            const label: []const u8 = switch (rows.items[row_index]) {
                .root => |v| v.label,
                .directory => |v| v.label,
                .file, .recent_file => |v| v.label,
                else => continue,
            };
            if (label.len == 0) continue;
            line.clearRetainingCapacity();
            // **`cells` 는 격자가 아니라 그려진 셀만 담은 목록이다.** 처음엔 `row * cols + col` 로 훑었는데
            // 19 개 중 1 개만 맞았다 — 재구성이 틀린 것이지 그림이 틀린 것이 아니었다(스크린샷은 정확했다).
            // 각 셀이 자기 `row`·`col` 을 들고 있으므로 그것으로 고른다.
            for (frame.draw_list.cells) |cell| {
                if (cell.row != row_index or cell.codepoint == 0) continue;
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cell.codepoint), &enc) catch continue;
                try line.appendSlice(allocator, enc[0..n]);
            }
            labels_checked += 1;
            // 라벨이 칸보다 길면 잘린다 — 그때는 **앞부분**이 있는지 본다(자름 자체는 정상 동작이다).
            const needle = if (label.len > 16) label[0..16] else label;
            if (std.mem.indexOf(u8, line.items, needle) != null) labels_matched += 1;
        }
    }
    // **보고는 `renderer.frame_probe` 가 단일 출처다.** 처음엔 손으로 몇 줄을 골라 찍었는데, 그 모듈의
    // 머리말이 정확히 그 결함을 예고한다 — "각 smoke가 따로 구현하면 GlyphFrameStats 가 바뀔 때마다
    // 여러 곳을 손으로 맞춰야 하고 키 schema 도 서로 어긋난다(**한 smoke만 fallback_count 를 빼먹는
    // 식**)." 적대적 검증에서 이모지 이름이 두부(□)로 그려지는데 내 보고에 그 사실이 **한 줄도 없던**
    // 것을 보고 알았다. 지금은 `fallback_count`·`replacement_count` 가 자동으로 실린다.
    const stats = maru.renderer.renderFrameStats(frame, host.renderer_state.atlas.entryCount());

    try stdout.writeAll("maru.win32-file-tree-draw-smoke.v1\n");
    try stdout.print("root={s}\n", .{root_path});
    try stdout.print("cell_px={d}x{d} grid={d}x{d}\n", .{ cell_w, cell_h, grid.cols, grid.rows });
    try stdout.print("rows={d} drawn_rows={d}\n", .{ rows.items.len, visible });
    // **그림의 지문이다.** `pipeline.draw` 가 받는 것이 이 배열 전부라 같은 값이면 같은 화면이다.
    // 리팩터 전후를 눈이 아니라 숫자로 대조하려고 낸다(`d3d11_cells.cellsDigest` 의 doc).
    try stdout.print("d3d_cells={d} cells_digest=0x{X:0>16} atlas_region_uploads={d}\n", .{ cells.items.len, d3d11_cells.cellsDigest(cells.items), region_uploads });
    try stdout.print("frames_presented={d}\n", .{frames});
    try stdout.print("labels_matched={d}/{d}\n", .{ labels_matched, labels_checked });
    try stdout.print("selected_row={?d} band_cells={d}\n", .{ selected_row, band_cells });
    try maru.renderer.writeRenderFrameStats(stdout, "renderer_", stats);
    try stdout.flush();

    // **판정은 프레임 수가 아니라 준비된 프레임이다.** 프레임만 세면 빈 창도 초록이다 — ⒜ 에서 행 수만
    // 세면 빈 스캔이 초록이던 것과 같은 부류다. `prepared()` 는 내부 일관성에 더해 글리프가 실제로
    // 잡혔고 아틀라스가 채워졌는지까지 본다 — 손으로 짠 `cells.len != 0` 보다 강하다.
    // 선택이 있으면 띠도 **전폭**이어야 한다. 몇 칸만 깔리면 화면에서는 그럴듯한데 행 끝이 비어
    // 선택이 어디서 끝나는지 안 보인다 — 수를 세는 것이 그것을 잡는다.
    const band_ok = if (selected_row == null) band_cells == 0 else band_cells == grid.cols;
    if (!stats.prepared() or cells.items.len == 0 or labels_checked == 0 or labels_matched != labels_checked or !band_ok) {
        try stderr.writeAll("maru win32-file-tree-draw-smoke: the frame was not prepared\n");
        try stderr.flush();
        return error.NothingDrawn;
    }
}

/// `maru win32-git-smoke` — W8.4. **git 백엔드가 Windows 에서 제품 경로로 돈다.**
///
/// **이 스모크가 없으면 그 코드는 분석조차 안 된다.** Windows 갈래는 `comptime` 분기 뒤에 있어 아무도
/// 안 부르면 컴파일러가 안 본다 — 실제로 없는 함수를 부르는 채로 `zig build` 가 통과했고, 강제 참조로
/// 재고 나서야 드러났다. 단위 테스트로는 못 메운다: `git_backend.zig` 를 테스트 루트로 세우면 그 파일의
/// **POSIX 전용 테스트 본문**(`std.c.pipe`·`std.c.fork`)까지 분석돼 Windows 에서 깨진다(런타임
/// `SkipZigTest` 는 컴파일을 막지 못한다).
///
/// 그래서 파일 트리와 같은 방식으로 **제품 진입점**을 태운다 — `Backend.submitRepoStatus` →
/// 백그라운드 스레드 → `takeRepoStatusResult`. 백엔드가 실제로 쓰는 길이고, 중간을 건너뛰면 그 자리가
/// 안 밟힌다(⒜ 에서 `submit` 과 `submitValidatedRootScan` 을 헷갈려 W8.1 수정을 하나도 안 밟았던 것과
/// 같은 종류의 실수를 막는다).
fn runWin32GitSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-git-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    // ── 임시 저장소를 만든다 ─────────────────────────────────────────────────────────────────
    //
    // 이 저장소를 그대로 쓰면 커밋 상태에 따라 결과가 달라져 통과가 무엇을 뜻하는지 흐려진다.
    const cwd = std.Io.Dir.cwd();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_native = root_buf[0..try cwd.realPath(io, &root_buf)];
    const cwd_norm = try maru.path_shape.normalizeSeparators(allocator, cwd_native);
    defer allocator.free(cwd_norm);
    const repo = try std.fmt.allocPrint(allocator, "{s}/zig-out/maru-git-smoke", .{cwd_norm});
    defer allocator.free(repo);
    cwd.deleteTree(io, repo) catch {};
    try cwd.createDir(io, repo, .default_dir);

    var init_out = maru.win32_process.capture(allocator, &.{ "git", "init", "-q" }, repo, .stdout_only, &.{}, &.{}, 1 << 20) catch |err| {
        try stderr.print("maru win32-git-smoke: git init failed({s})\n", .{@errorName(err)});
        try stderr.flush();
        return error.UnknownCommand;
    };
    init_out.deinit(allocator);

    // **비-ASCII 이름을 하나 섞는다.** 경로가 WTF-8 로 끝까지 가는지가 숨은 판정이고, 깨지면 한글
    // 사용자 이름을 가진 기기에서 목록이 통째로 빈다.
    const names = [_][]const u8{ "alpha.txt", "\u{d55c}\u{ae00}.txt" };
    for (names) |name| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo, name });
        defer allocator.free(p);
        try cwd.writeFile(io, .{ .sub_path = p, .data = "x" });
    }

    // ── 제품 진입점 ──────────────────────────────────────────────────────────────────────────
    var backend = try git_backend_mod.Backend.init(io);
    defer backend.deinit();
    if (!backend.submitRepoStatus("git", repo, 1)) {
        try stderr.writeAll("maru win32-git-smoke: could not submit the repo status request\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    // **상한을 실제로 강제한다.** 결과가 안 오면 빈 결과가 아니라 실패다.
    var rounds: usize = 0;
    var result: ?git_backend_mod.RepoStatusResult = null;
    while (rounds < 6000) : (rounds += 1) {
        if (backend.takeRepoStatusResult()) |taken| {
            result = taken;
            break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    var status = result orelse {
        try stderr.writeAll("maru win32-git-smoke: the repo status did not finish in time\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    // **`worker_allocator` 로 해제한다.** 결과는 백그라운드 스레드가 그 할당기로 만든다 — 스모크의
    // 할당기로 해제하면 "Invalid free" 다(실측: 처음에 그렇게 짜서 패닉했다). 제품도 같은 자리에서
    // `git_backend_mod.worker_allocator` 를 쓴다(`scm_dock.zig`).
    defer status.deinit(git_backend_mod.worker_allocator);

    // ── 판정: 내용이다 ───────────────────────────────────────────────────────────────────────
    //
    // `ok` 만 보면 **빈 출력도 통과**한다. porcelain v2 는 추적되지 않은 파일을 `? <경로>` 로 내므로
    // 두 이름이 실제로 실려 왔는지 본다.
    var found_alpha = false;
    var found_hangul = false;
    var it = maru.session.git_status.iterate(status.text);
    var entries: usize = 0;
    while (it.next()) |entry| {
        entries += 1;
        if (std.mem.indexOf(u8, entry.path, "alpha.txt") != null) found_alpha = true;
        if (std.mem.indexOf(u8, entry.path, "\u{d55c}\u{ae00}.txt") != null) found_hangul = true;
    }
    const head = maru.session.git_status.parseHead(status.text);

    try stdout.writeAll("maru.win32-git-smoke.v1\n");
    try stdout.print("repo={s}\n", .{repo});
    try stdout.print("ok={} text_bytes={d}\n", .{ status.ok, status.text.len });
    try stdout.print("branch={s}\n", .{head.branch orelse "(none)"});
    try stdout.print("entries={d}\n", .{entries});
    try stdout.print("found: alpha={} hangul={}\n", .{ found_alpha, found_hangul });
    try stdout.flush();

    // ── 쓰기 경로 ────────────────────────────────────────────────────────────────────────────
    //
    // 읽기와 **다른 자리**를 탄다(`runWriteSync` → stderr 를 받는다). 읽기만 재고 넘어가면 그 갈래는
    // 분석조차 안 된 채 남는다 — 이 슬라이스가 그것으로 한 번 데였다.
    //
    // **결과를 상태로 확인한다.** 종료 코드만 보면 `add` 가 아무것도 안 해도 통과한다. 스테이지한 뒤
    // 다시 읽어 그 파일이 **staged 축**으로 옮겨졌는지 본다.
    var write_out = git_backend_mod.runWriteSync(allocator, .stage, "git", repo, &.{"alpha.txt"}, null) catch |err| {
        try stderr.print("maru win32-git-smoke: stage failed({s})\n", .{@errorName(err)});
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer allocator.free(write_out.stderr_bytes);

    if (!backend.submitRepoStatus("git", repo, 2)) {
        try stderr.writeAll("maru win32-git-smoke: could not submit the second repo status request\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    var rounds2: usize = 0;
    var after: ?git_backend_mod.RepoStatusResult = null;
    while (rounds2 < 6000) : (rounds2 += 1) {
        if (backend.takeRepoStatusResult()) |taken| {
            after = taken;
            break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    var status2 = after orelse {
        try stderr.writeAll("maru win32-git-smoke: the second repo status did not finish in time\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer status2.deinit(git_backend_mod.worker_allocator);

    // porcelain v2 의 추적되는 항목은 `1 <XY> …` 로 오고 `XY` 의 **첫 글자가 index 축**이다.
    // 스테이지된 새 파일은 `A.` 다 — 추적되지 않은 `?` 에서 옮겨 왔다는 뜻이다.
    var staged_alpha = false;
    var untracked_after: usize = 0;
    var it2 = maru.session.git_status.iterate(status2.text);
    while (it2.next()) |entry| {
        // `staged` 가 index 축이다. 추적되지 않던 파일을 `add` 하면 그 축이 `added` 가 된다.
        if (entry.staged == .unchanged) untracked_after += 1;
        if (std.mem.indexOf(u8, entry.path, "alpha.txt") != null and entry.staged == .added) staged_alpha = true;
    }

    try stdout.print("write: exit={d} stderr_bytes={d}\n", .{ write_out.exit_code, write_out.stderr_bytes.len });
    try stdout.print("after: staged_alpha={} untracked={d}\n", .{ staged_alpha, untracked_after });
    try stdout.flush();

    if (!write_out.ok() or !staged_alpha) {
        try stderr.writeAll("maru win32-git-smoke: the stage did not move the file into the index\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    if (!status.ok or !found_alpha or !found_hangul) {
        try stderr.writeAll("maru win32-git-smoke: the status did not carry the fixture names\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
}

/// `maru win32-terminal-smoke` — W7.2c-2. **actual 터미널 화면이 Windows에 뜬다.**
///
/// W7.2c-1이 세운 프레임(actual PTY → Windows 셰이퍼 → DirectWrite)을 W7.2b가 세운 표시 경로에 흘려 넣는다.
/// 그 사이를 잇는 것이 둘이다:
///
/// ⑴ **아틀라스 부분 업로드** — 프레임마다 새 글리프만 `UpdateSubresource`로 올린다(전체를 다시 올리지 않는다).
/// ⑵ **셀 투영** — `metal_frame`의 `NativeMetalCell`을 `d3d11_cells.Cell`로 옮긴다(좌표계와 색 표현만 바꾼다).
///
/// 창 크기가 바뀌면 **터미널 격자도 바꾼다**(`resizeActiveSurface`) — 스왑체인만 맞추면 셸이 옛 크기로
/// 계속 출력해 줄이 어긋난다.
/// 스모크가 도는 최대 스핀 수. 한 스핀이 약 16ms 라 대략 10 초다 — 사람이 눈으로 보기에 충분하고
/// 자동 캡처가 기다릴 수 있는 길이다. **앱(`win32-terminal`)에는 이 상한이 없다.**
/// config 와 해석된 테마를 코어에 건다. **Windows 진입점 둘이 같은 값을 쓰도록 한 자리에 둔다.**
///
/// 리더 스레드가 뜨기 전에 부르므로 코어를 직접 만진다 — 큐를 거치는 것은 리더가 도는 동안의 규율이고,
/// 여기는 그 전이다(macOS 도 spawn 전에 같은 값을 적용한다).
fn applyCoreConfig(
    core: *maru.terminal.TerminalCore,
    cfg: maru.config.theme.Config,
    appearance: maru.config.appearance.ResolvedAppearance,
    cell_w: u32,
    cell_h: u32,
) void {
    _ = maru.session.core_command.apply(core, .{
        .set_runtime_config = .{
            .max_scrollback = cfg.scrollback.lines,
            .ambiguous_wide = cfg.ambiguous_width == .wide,
            .emoji_wide = cfg.emoji_width == .wide,
            .palette = appearance.theme.palette,
            .default_colors = .{ .foreground = appearance.theme.foreground, .background = appearance.theme.background },
            .cell_metrics = .{ .width = cell_w, .height = cell_h },
            // config 의 모양 enum 과 코어의 것은 **다른 타입**이다(같은 세 값이지만 층이 다르다).
            // macOS 도 같은 자리에서 옮긴다(`configCursorShape`).
            .default_cursor_shape = switch (appearance.cursor.shape) {
                .block => .block,
                .bar => .bar,
                .underline => .underline,
            },
        },
    });
}

// **판정 단계가 늘면 함께 올린다.** 상한을 넘긴 단계는 조용히 안 도는데, 그때 판정 값은 초기값
// 그대로라 "기능이 죽었다" 로 읽힌다(실측 2026-08-26: 그룹 다시 펴기가  이었다).
const smoke_spin_cap: usize = 1060;

test "상태바 경로: 홈만 ~ 로 줄이고, 애매하면 원본을 둔다" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    // 홈 아래면 줄인다.
    try t.expectEqualStrings("~/proj", shortenHome("C:/u/me/proj", "C:/u/me", &buf));
    // 홈 자체는 `~` 하나다.
    try t.expectEqualStrings("~", shortenHome("C:/u/me", "C:/u/me", &buf));
    // **접두사만 같은 다른 폴더는 안 줄인다** — `C:/u/mexico` 가 `~xico` 가 되면 안 된다.
    try t.expectEqualStrings("C:/u/mexico", shortenHome("C:/u/mexico", "C:/u/me", &buf));
    // 홈을 모르면 원본.
    try t.expectEqualStrings("C:/u/me/proj", shortenHome("C:/u/me/proj", null, &buf));
    // 다른 드라이브면 원본.
    try t.expectEqualStrings("D:/ohah/maru", shortenHome("D:/ohah/maru", "C:/u/me", &buf));
    // **버퍼가 모자라면 자르지 않고 원본을 준다** — 자르는 것은 텍스트 단계의 일이다(계약 §3).
    var tiny: [3]u8 = undefined;
    try t.expectEqualStrings("C:/u/me/proj", shortenHome("C:/u/me/proj", "C:/u/me", &tiny));
    // Windows 구분자도 같은 규칙이다.
    try t.expectEqualStrings("~\\proj", shortenHome("C:/u/me\\proj", "C:/u/me", &buf));
}

test "판정용 앞부분: 안 잘린 문자열은 그대로, 잘리면 글자 경계에서" {
    const t = std.testing;
    // **안 잘렸으면 손대지 않는다.** 세 바이트짜리 한글 제목이 통째로 사라지던 자리다 — 남는 것이
    // 0 이면 `needle.len >= 3` 에 걸려 **그려졌는데도 안 세어진다**.
    try t.expectEqualStrings("네", codepointPrefix("네", 8));
    try t.expectEqualStrings("abc", codepointPrefix("abc", 8));
    // 잘릴 때는 글자 경계로 물러난다 — 반쪽 글자가 남으면 어떤 문자열에서도 못 찾는다.
    try t.expectEqualStrings("마루 ", codepointPrefix("마루 프로젝트", 8));
    try t.expectEqualStrings("resume-b", codepointPrefix("resume-background-agent", 8));
    // 첫 글자부터 경계를 넘으면 빈 값 — 호출부가 `>= 3` 으로 거른다.
    try t.expectEqualStrings("", codepointPrefix("마", 2));
}

test "합성 기하: 창이 좁으면 도크가 사라지고, 있을 때는 겹치지 않는다" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const cell_w: u32 = 9;
    const cell_h: u32 = 19;
    var saw_dock = false;
    var saw_no_dock = false;
    var w: u32 = 40;
    while (w <= 1600) : (w += 37) {
        const g = dockGeometryFor(w, 640, cell_w, cell_h, true, 0, .explorer, 0, 0, 0);
        // 창을 넘지 않는다.
        try std.testing.expect(g.terminal.x + g.terminal.w <= w);
        try std.testing.expect(g.dock.x + g.dock.w <= w);
        if (g.dock.w == 0) {
            // **좁으면 도크가 통째로 사라진다** — 그때 터미널이 창 전폭을 갖는다. 처음에 이것을
            // 겹침으로 잘못 읽어 테스트가 실패했다(코드가 아니라 테스트가 틀렸다).
            saw_no_dock = true;
            try std.testing.expectEqual(w, g.terminal.w);
        } else {
            saw_dock = true;
            // 도크가 있으면 터미널·디바이더·도크가 이 순서로 겹치지 않고 선다.
            try std.testing.expect(g.terminal.x + g.terminal.w <= g.divider.x);
            try std.testing.expect(g.divider.x + g.divider.w <= g.dock.x);
        }
        // **격자 유도가 `cellsForClient` 의 clamp 를 따라간다.** 판정 기준값이 이 함수를 안 쓰고
        // 나눗셈만 하면, 터미널 폭이 셀 하나보다 작아지는 순간 멀쩡한 창에서
        // `grid_follows_term_rect=false` 가 나온다. (이 표에서는 그 폭이 안 나오지만, 기준값이
        // 같은 함수를 지나야 그 갈래가 애초에 생기지 않는다.)
        const via_helper = win32_window.cellsForClient(g.terminal.w, g.terminal.h, cell_w, cell_h).?;
        try std.testing.expect(via_helper.cols >= 1);
    }
    // 두 갈래를 다 지났는가 — 안 지났으면 이 테스트는 아무것도 안 잰 것이다.
    try std.testing.expect(saw_dock and saw_no_dock);
}

/// 도크 자리에 그릴 **파일 트리 프레임**(W8.7a2). 도크가 없으면 `null` 이다.
///
/// **터미널과 같은 `RendererState` 를 지난다** — 그래야 아틀라스 슬롯이 안 충돌한다. 두 프레임이
/// 각자 아틀라스를 들면 같은 텍스처를 서로 덮어써 글자가 다른 글자로 나온다(§2m.6 이 부분 업로드에서
/// 적어 둔 것과 같은 부류의 오답이다).
///
/// **격자는 `tree_content` 사각형에서 나온다** — 터미널이 자기 사각형에서 격자를 얻는 것과 같은
/// 규율이다(§2m.31 ⒜1). 창에서 유도하면 트리가 도크보다 넓다고 믿어 이름이 잘리지 않는다.
fn buildDockTreeFrame(
    allocator: std.mem.Allocator,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    rows: []const maru.session.file_tree.Row,
    geom: maru.session.dock_layout.Geometry,
    cell_w: u32,
    cell_h: u32,
    /// 콘텐츠가 위로 밀린 양(px). 0 이면 맨 위다.
    scroll_px: u32,
    /// 첫 행이 뷰포트 위로 밀려 나간 픽셀 — 렌더가 원점을 그만큼 **올려** 그린다.
    shift_out: *u32,
    /// **실제로 그린 첫 행.** 판정이 `drawWindow` 를 다시 부르면 그리기 쪽만 어긋나도 안 잡힌다
    /// (실측: 그리기에 스크롤을 안 주는 뮤턴트가 그 판정을 통과했다).
    start_out: *usize,
    /// **실제로 그린 행 수.** 히트테스트가 이 값을 써야 한다 — `rows.len` 을 쓰면 안 그린 행이
    /// 눌린다(실측: 110 행짜리 디렉터리에서 도크 맨 아래를 누르면 그리지 않은 29 행이 나왔다).
    drawn: *u16,
) !?maru.renderer.RenderFrame {
    drawn.* = 0;
    const area = geom.tree_content;
    if (area.w < cell_w or area.h < cell_h) return null;
    // **거터를 뺀 폭이 글자의 폭이다**(`scrollGutterPx` 의 doc). 안 빼면 스크롤바가 마지막 칸
    // 위에 겹쳐 그려진다 — 중립이 "목록 위에 겹쳐 그리는 대안은 사용자가 겹쳐 보인다고 보고한
    // 바로 그 상태" 라고 적어 둔 자리다.
    const text_w = area.w -| scrollGutterPx();
    if (text_w < cell_w) return null;
    const cols: u16 = @intCast(text_w / cell_w);
    // **어느 행을 그릴지는 중립이 정한다**(`file_tree_layout.drawWindow`) — 히트테스트
    // (`rowAtLocalY`)와 짝이라 그린 행과 눌리는 행이 안 갈린다. 여기서 다시 나누면 부분만 보이는
    // 첫 행에서 어긋난다(그 함수 doc 이 왜 올림인지까지 적어 뒀다).
    const win = maru.session.file_tree_layout.drawWindow(cell_h, scroll_px, area.h, rows.len);
    drawn.* = win.count;
    shift_out.* = win.origin_shift_px;
    start_out.* = win.start;
    if (cols == 0 or win.count == 0) return null;

    const fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 } };
    const active_fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    var list = try cell_text.buildFileTreeDrawList(
        allocator,
        rows,
        null,
        win.start,
        win.count,
        cols,
        fg,
        active_fg,
        null,
        null,
        null,
    );
    // **DrawList 소유권은 프레임으로 넘어간다** — 실패했을 때만 우리가 해제한다(§2m.6 이 double
    // free 로 배운 자리).
    return renderer_state.buildFrameFromDrawListWithRasterizer(allocator, list, builder.shaper, builder.rasterizer) catch |err| {
        list.deinit(allocator);
        return err;
    };
}

/// 도크 자리 전부를 다시 만든다 — 배경·디바이더·**파일 트리 글자**. 새 트리 프레임을
/// `frame_slot` 에 넣고 옛 것을 해제한다.
///
/// 호출자는 이 뒤에 그 프레임의 **글리프 영역을 아틀라스에 올려야** 한다. 여기서 올리지 않는 이유는
/// 파이프라인이 이 함수 밖에 있고, 아틀라스가 커졌을 때 텍스처를 다시 만드는 순서(먼저 resize,
/// 그 다음 upload)를 호출자가 이미 알고 있기 때문이다.
fn rebuildDockAll(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    geom: maru.session.dock_layout.Geometry,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    rows: []const maru.session.file_tree.Row,
    cell_w: u32,
    cell_h: u32,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    outside: *usize,
    /// 트리가 위로 밀린 양(px)과 그 나머지(첫 행이 잘린 픽셀 — 렌더가 원점을 그만큼 올린다).
    scroll_px: u32,
    shift_out: *u32,
    start_out: *usize,
    /// 트리 글자 중 **가장 위 픽셀**. 부분 스크롤(`shift`)을 실제로 적용했는지의 유일한 관측점 —
    /// 안 하면 스크롤이 행 단위로 툭툭 끊기는데 개수·행 판정은 전부 초록이다(실측).
    top_px_out: *?f32,
    drawn: *u16,
    frame_slot: *?maru.renderer.RenderFrame,
    /// 지금 도크가 보이는 것. **뷰마다 다른 표면**을 그린다(W8.7c2).
    view: maru.session.dock_panel.View,
    tk: *const maru.chrome.Tokens,
    view_bar_frame: *?maru.renderer.RenderFrame,
    view_bar_glyph_top: *?f32,
    /// 소스 컨트롤 뷰가 쓰는 것들. `status` 가 비어 있으면 그 뷰는 아무것도 안 그린다.
    scm: ScmDockInputs,
    /// 에이전트 세션 뷰가 쓰는 것들.
    agent: AgentDockInputs,
) !void {
    try rebuildDockCells(allocator, out, geom, tk);
    if (view != .explorer) {
        if (frame_slot.*) |*old_frame| {
            old_frame.deinit(allocator);
            frame_slot.* = null;
        }
        drawn.* = 0;
        if (view == .source_control) try appendScmDockCells(allocator, out, geom, renderer_state, builder, cell_w, cell_h, pipeline, atlas_w, atlas_h, uploaded, scm);
        // **셋째 칸이 더 이상 빈 도크가 아니다**(W8.5b⒜). 목록은 아직 비어 있고 컴포넌트가 그 상태의
        // 안내를 그린다 — "비었다" 와 "조립이 깨졌다" 는 다른 사실이라 판정이 그 둘을 가른다.
        if (view == .agent_sessions) try appendAgentDockCells(allocator, out, geom, renderer_state, builder, cell_w, cell_h, pipeline, atlas_w, atlas_h, uploaded, agent);
        // **뷰 바는 내용 뒤에 굽는다.** 먼저 구우면 그 뒤 내용이 아틀라스를 키울 때 UV 가 낡아
        // **다른 글리프가 나온다**(실측: 폴더·git·code 자리에 git·폴더·git 이 떴다). §2m.32 가
        // "업로드 목록은 프레임과 함께 사라진다" 를 적었다면, 이것은 그 짝인 **UV 낡음**이다.
        appendViewBarCells(allocator, out, geom, cell_w, cell_h, view, tk, renderer_state, builder, pipeline, atlas_w, atlas_h, uploaded, view_bar_frame, view_bar_glyph_top) catch {};
        return;
    }
    if (frame_slot.*) |*old| {
        old.deinit(allocator);
        frame_slot.* = null;
    }
    if (rows.len == 0) return;
    const built = (try buildDockTreeFrame(allocator, renderer_state, builder, rows, geom, cell_w, cell_h, scroll_px, shift_out, start_out, drawn)) orelse return;
    frame_slot.* = built;

    // **업로드는 여기서, 지금 한다.** 프레임의 업로드 목록은 **그 프레임과 함께 사라진다** — 올리기
    // 전에 다시 지으면 그 글리프는 영영 GPU 에 안 간다. 그리고 아틀라스 캐시는 터미널과 **공유**라
    // 그 뒤로는 "이미 있다" 고 판단해 터미널도 다시 안 올린다: 실측으로 **터미널 글자까지 깨졌다**
    // (첫 프레임 `uploads=53` → 시작 직후 리사이즈가 그것을 버리고 `uploads=0` 인 프레임으로 교체).
    const now_w = renderer_state.atlas.config.atlas_width_px;
    const now_h = renderer_state.atlas.config.atlas_height_px;
    if (now_w != atlas_w.* or now_h != atlas_h.*) {
        try pipeline.resizeAtlas(now_w, now_h);
        atlas_w.* = now_w;
        atlas_h.* = now_h;
    }
    const trf = built.glyph_raster_frame;
    for (trf.uploads) |up| {
        const bytes = trf.pixels[up.bytes_offset..][0..up.byte_count];
        pipeline.uploadAtlasRegion(up.slot.x_px, up.slot.y_px, up.slot.width_px, up.slot.height_px, bytes, up.bytes_per_row) catch continue;
        uploaded.* += 1;
    }

    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 },
        .default_bg = .{ .r = 0x18, .g = 0x1D, .b = 0x28 },
    };
    const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(
        allocator,
        built.glyph_quad_frame,
        built.draw_list.cells,
        colors,
    );
    defer allocator.free(native);
    // **여기서는 원점이 실제로 일을 한다** — 도크는 창 오른쪽이라 `tree_content.x` 가 0 이 아니다
    // (터미널 쪽에서는 그 배선이 아직 안 밟힌다 — §2m.31).
    maru.renderer.metal_frame.setCellsPaneOrigin(native, geom.tree_content.x, geom.tree_content.y);
    try out.ensureUnusedCapacity(allocator, native.len);
    // **첫 행이 잘린 만큼 위로 올린다.** `drawWindow` 가 뷰포트를 덮으려고 한 줄 더 주고 그 나머지를
    // `origin_shift_px` 로 알려 준다 — 안 올리면 스크롤이 **행 단위로만** 움직여 툭툭 끊긴다.
    const shift_f: f32 = @floatFromInt(shift_out.*);
    top_px_out.* = null;
    const x0: f32 = @floatFromInt(geom.tree_content.x);
    const y0: f32 = @floatFromInt(geom.tree_content.y);
    const x1: f32 = @floatFromInt(geom.tree_content.x + geom.tree_content.w);
    const y1: f32 = @floatFromInt(geom.tree_content.y + geom.tree_content.h);
    for (native) |n| {
        var cell = win32_terminal.cellFromNative(n, cell_w, cell_h, atlas_w.*, atlas_h.*);
        cell.rect[1] -= shift_f;
        // **뷰포트 위아래로 반쯤 걸친 행은 정상이다.** `drawWindow` 는 바닥에 배경 띠가 남지 않게
        // 일부러 한 줄 더 주고(그 함수 doc 이 "올림이어야 한다" 고 적어 뒀다), 첫 행은 `shift` 만큼
        // 위로 밀린다. 그 둘을 `outside` 로 세면 스크롤만 해도 판정이 빨개진다(실측: 48 행 트리에서
        // 40 — 마지막 한 행의 글자 수 그대로였다). **좌우 두 변과 완전히 벗어난 셀은 그대로 잰다.**
        const spans_top = cell.rect[1] < y0 and cell.rect[1] + cell.rect[3] > y0;
        const spans_bottom = cell.rect[1] < y1 and cell.rect[1] + cell.rect[3] > y1;
        if ((spans_top or spans_bottom) and cell.rect[0] >= x0 and cell.rect[0] + cell.rect[2] <= x1) {
            if (top_px_out.* == null or cell.rect[1] < top_px_out.*.?) top_px_out.* = cell.rect[1];
            out.appendAssumeCapacity(cell);
            continue;
        }
        // 완전히 아래로 나간 행은 **그리지 않는다** — 도크 밖이라 그릴 이유가 없다.
        if (cell.rect[1] >= y1) continue;
        // **트리 글자가 도크 사각형을 벗어나면 안 된다.** 여기서 원점을 안 찍으면 글자가 창 왼쪽
        // 위에서 시작해 **터미널 위에** 얹힌다 — 터미널 쪽과 달리 이 판정은 실제로 발동한다
        // (`tree_content.x` 가 0 이 아니다).
        if (cell.rect[0] < x0 or cell.rect[1] < y0 or
            cell.rect[0] + cell.rect[2] > x1 or cell.rect[1] + cell.rect[3] > y1) outside.* += 1;
        if (top_px_out.* == null or cell.rect[1] < top_px_out.*.?) top_px_out.* = cell.rect[1];
        out.appendAssumeCapacity(cell);
    }
    // 위 주석과 같은 이유로 **내용 뒤에** 굽는다.
    appendViewBarCells(allocator, out, geom, cell_w, cell_h, view, tk, renderer_state, builder, pipeline, atlas_w, atlas_h, uploaded, view_bar_frame, view_bar_glyph_top) catch {};
}

/// 상단 띠 전체 — 배경 + 캡션 버튼.
fn rebuildTitlebarCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    client_w: u32,
    /// **띠의 왼쪽 이만큼은 우리 것이 아니다** — 사이드바 헤더의 아이콘 줄이 그 자리를 그린다
    /// (`dock_layout.sidebarOf`). 안 비우면 이 채움이 **나중에 그려져 아이콘을 덮는다**: 실측
    /// 2026-08-25 에 아이콘이 통째로 사라졌고, 띠에 잉크가 하나도 안 남았다(`y 0..38` 전부 배경).
    /// 히트테스트가 왼쪽을 도려내는 폭과 **같은 값**이어야 한다 — 갈리면 보이는 것과 눌리는 것이
    /// 어긋난다.
    sidebar_w: u32,
    titlebar_px: u32,
    btn_w: u32,
    hovered: ?usize,
    maximized: bool,
    tk: *const maru.chrome.Tokens,
) !void {
    out.clearRetainingCapacity();
    if (titlebar_px == 0) return;
    const fill_x = @min(sidebar_w, client_w);
    try out.append(allocator, d3d11_cells.solidCell(
        @floatFromInt(fill_x),
        0,
        @floatFromInt(client_w -| fill_x),
        @floatFromInt(titlebar_px),
        cellColor(tk, .surface_bg),
        .{ 0, 0, 0, 0 },
    ));
    try appendCaptionButtons(allocator, out, client_w, titlebar_px, btn_w, hovered, maximized, tk);
}

/// 캡션 버튼 셋(─ ☐ ✕)의 자리. **Windows 관례대로 오른쪽 끝**, 닫기가 가장 오른쪽이다.
///
/// 폭·높이를 셀에서 유도하므로 폰트가 커지면 버튼도 함께 커진다(§2m.37 의 결정 ⑷).
fn captionButtonRects(client_w: u32, titlebar_px: u32, btn_w: u32) [3]maru.session.split_tree.Rect {
    const y: u32 = 0;
    const h = titlebar_px;
    const right = client_w;
    return .{
        .{ .x = right -| btn_w * 3, .y = y, .w = btn_w, .h = h }, // ─ 최소화
        .{ .x = right -| btn_w * 2, .y = y, .w = btn_w, .h = h }, // ☐ 최대화/복원
        .{ .x = right -| btn_w, .y = y, .w = btn_w, .h = h }, // ✕ 닫기
    };
}

/// 캡션 버튼을 그린다. **아이콘이 아니라 선이다** — 최소화·최대화·닫기는 등록 아이콘 자산이 없고,
/// Windows 관례의 그 모양(가로선·사각형·엑스)은 셀 몇 개로 정확히 낼 수 있다.
///
/// **닫기만 호버에서 빨강**이다(Windows 11 관례). 나머지는 은은한 면만 깔린다.
fn appendCaptionButtons(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    client_w: u32,
    titlebar_px: u32,
    btn_w: u32,
    hovered: ?usize,
    maximized: bool,
    tk: *const maru.chrome.Tokens,
) !void {
    if (titlebar_px == 0 or btn_w == 0) return;
    const rects = captionButtonRects(client_w, titlebar_px, btn_w);
    const fg = tk.get(.surface_fg);
    for (rects, 0..) |r, i| {
        if (hovered) |hv| if (hv == i) {
            const hover_argb: u32 = if (i == 2) 0xFFC42B1C else blk: {
                const c = tk.get(.tab_hover_bg);
                break :blk 0xFF000000 | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
            };
            try out.append(allocator, d3d11_cells.solidCell(
                @floatFromInt(r.x),
                @floatFromInt(r.y),
                @floatFromInt(r.w),
                @floatFromInt(r.h),
                d3d11_cells.colorFromArgb(hover_argb),
                .{ 0, 0, 0, 0 },
            ));
        };
        // 글리프 색은 닫기 호버일 때만 흰색으로 뒤집는다(빨강 위 대비).
        const ink = if (hovered != null and hovered.? == i and i == 2)
            d3d11_cells.colorFromArgb(0xFFFFFFFF)
        else
            d3d11_cells.colorFromArgb(0xFF000000 | (@as(u32, fg.r) << 16) | (@as(u32, fg.g) << 8) | fg.b);
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        const s: u32 = 5; // 표식 반폭 — 관례상 10px 안팎이다
        switch (i) {
            0 => try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(cx -| s), @floatFromInt(cy), @floatFromInt(s * 2), 1, ink, .{ 0, 0, 0, 0 })),
            1 => {
                // 최대화면 **겹친 사각형 둘**(복원), 아니면 사각형 하나. 테두리는 선 넷으로 낸다.
                try appendRectOutline(allocator, out, cx -| s, cy -| s, s * 2, s * 2, ink);
                if (maximized) try appendRectOutline(allocator, out, cx -| s + 3, cy -| s - 3, s * 2, s * 2, ink);
            },
            else => {
                // ✕ — 대각선은 셀로 못 그리니 짧은 가로 조각을 계단으로 쌓는다.
                var k: u32 = 0;
                while (k < s * 2) : (k += 1) {
                    try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(cx -| s + k), @floatFromInt(cy -| s + k), 1, 1, ink, .{ 0, 0, 0, 0 }));
                    try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(cx -| s + k), @floatFromInt(cy + s - k), 1, 1, ink, .{ 0, 0, 0, 0 }));
                }
            },
        }
    }
}

fn appendRectOutline(allocator: std.mem.Allocator, out: *std.ArrayList(d3d11_cells.Cell), x: u32, y: u32, w: u32, h: u32, ink: [4]f32) !void {
    try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(x), @floatFromInt(y), @floatFromInt(w), 1, ink, .{ 0, 0, 0, 0 }));
    try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(x), @floatFromInt(y + h - 1), @floatFromInt(w), 1, ink, .{ 0, 0, 0, 0 }));
    try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(x), @floatFromInt(y), 1, @floatFromInt(h), ink, .{ 0, 0, 0, 0 }));
    try out.append(allocator, d3d11_cells.solidCell(@floatFromInt(x + w - 1), @floatFromInt(y), 1, @floatFromInt(h), ink, .{ 0, 0, 0, 0 }));
}

/// 왼쪽 사이드바를 채우는 셀 — **배경 띠와 세션 카드**(W8.8⒜1).
///
/// **기하는 중립이 소유한다**(`chrome/components/sidebar.zig` 의 `Metrics`·`cardHeight`·`rowTop`).
/// 여기서 다시 곱하면 그린 자리와 눌리는 자리의 주인이 둘이 된다 — 이 세션에서 §2m.34 가 그 실패를
/// 이미 한 번 겪었다.
///
/// **글자는 아직 없다**(⒜2). 카드 밴드와 좌측 앰버 막대까지가 ⒜1 이고, 판정은 "창이 셋으로 갈리고
/// 터미널이 사이드바를 안 침범하는가" 다.
fn rebuildSidebarCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    geom: maru.session.dock_layout.Geometry,
    /// 창의 타이틀 띠 높이. 헤더의 아이콘 줄이 **그 띠 자체**다 — 창 버튼과 같은 줄에 서야 한다.
    titlebar_px: u32,
    sidebar_w: u32,
    cell_w: u32,
    cell_h: u32,
    /// 카드에 실을 것들 — **세션 하나에 한 장**. 슬라이스라 호출자가 수명을 안다.
    cards: []const SidebarCard,
    /// 활성 세션의 카드 — 앰버 막대가 여기만 선다.
    active_card: usize,
    tk: *const maru.chrome.Tokens,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    glyphs: *usize,
    outside: *usize,
    frame_slot: *?maru.renderer.RenderFrame,
    header_frame_slot: *?maru.renderer.RenderFrame,
    /// 헤더가 실제로 차지한 높이(px). 카드가 그만큼 내려가고, 히트테스트도 같은 값을 봐야 한다.
    header_h_out: *u32,
    /// 아이콘 밴드 높이 — `headerHit` 이 이 값으로 아이콘 사각형을 잡는다. 판정이 헤더 높이를
    /// 대신 넣으면 엉뚱한 y 를 찌른다(실측: `header_routed=0/4`).
    header_icon_band_out: *u32,
    /// **헤더 전용 카운터.** 카드와 섞으면 어느 쪽이 샜는지 못 가린다 — 판정이 그만큼 무뎌진다.
    /// **줄별로 센다.** 합계 하나면 "아이콘 넷 + 검색 일곱" 과 "아이콘 열하나" 를 못 가른다 —
    /// 매직넘버 `11` 로 재던 판이 그랬다.
    header_icon_glyphs: *usize,
    header_search_glyphs: *usize,
    header_outside: *usize,
    /// **카드가 헤더를 덮는가.** 밴드와 글자가 *함께* 위로 올라가면 기존 판정이 전부 초록이다
    /// (실측: 그 뮤턴트가 살아남았다) — `sidebar_cells_outside` 가 **카드 밴드 기준**이라 밴드도
    /// 같이 움직이면 아무것도 안 걸린다. 그래서 헤더 바닥과 견준다.
    card_over_header: *usize,
    /// **위가 깎인** 목록 셀 수 — 판정이 빈말이 아님을 보이는 값이다(0 이면 자를 것이 없었거나
    /// 반쯤 걸친 줄을 통째로 버렸다는 뜻이고, 그때 `card_over_header == 0` 은 아무것도 안 지킨다).
    cells_clipped: *usize,
    /// 실제로 **그려진** 카드 수. 목록보다 적으면 나머지는 화면에 없고 누를 수도 없다 —
    /// 사이드바 스크롤이 붙기 전까지의 한계이고, 조용히 두지 않으려고 밖으로 낸다.
    cards_visible: *usize,
    /// **그린 자리**를 그대로 싣는다 — 판정이 `headerIconCol` 을 다시 부르면 동어반복이 된다
    /// (실측: 열을 하나 옮긴 뮤턴트가 그 판정을 통과했다).
    header_drawn: *DrawnHeaderIcons,
    /// 지금 가리키는 카드 · 헤더 영역. **그림이 바뀌어야 눌린 것이 보인다.**
    hover_slot: ?usize,
    hover_header: ?maru.chrome.components.sidebar.HeaderRegion,
    /// 카드 목록이 위로 밀린 양(px). **헤더는 스크롤 무관 고정**이다 — `slotAt` 의 doc 이 그 규칙을
    /// 소유한다("보이는=클릭되는"). 히트테스트는 **전체 목록**에 이 값을 넘기고, 그리기는 아래에서
    /// 같은 누적으로 **창**을 잘라 낸다. 둘이 어긋나면 그린 카드와 눌리는 카드가 갈린다.
    scroll_px: u32,
    /// 실제로 그린 **첫 카드**. 판정이 여기서 누적을 다시 하면 그리기 쪽만 어긋나도 안 잡힌다
    /// (도크에서 그 함정을 두 번 밟았다 — §2m.52).
    first_visible: *usize,
    /// 첫 보이는 카드 밴드가 **실제로 앉은 y**(px). 판정이 여기서 자리를 다시 계산하면 그리기 쪽만
    /// 어긋나도 안 잡힌다 — 그 자리를 눌러 `slotAt` 이 같은 카드를 내는지 본다.
    first_band_y: *u32,
    /// 첫 보이는 카드가 위로 잘린 픽셀(도크의 `origin_shift_px` 와 같은 뜻). 0 이면 카드 경계에
    /// 딱 맞은 것이라 **부분 스크롤을 시험하지 못한 상태**다 — 판정이 그것을 알아야 한다.
    partial_out: *u32,
    /// **활성 카드**의 밴드 y(안 보이면 null). 굴린 뒤 활성 표시가 엉뚱한 카드에 가는 것을 잡는다.
    active_band_y: *?u32,
    /// 카드 글자가 실제로 쓴 칸 수. **판정이 이 값을 스크롤바 자리와 견준다** — 판정 쪽에서
    /// 다시 계산하면 내가 쓴 식을 되읽는 꼴이라 거터를 빼는 것을 잊어도 안 움직인다.
    card_cols_out: *u16,
    /// 그리기가 쓴 **그 배치**. 히트테스트가 이것을 그대로 받아야 "보이는 칸 = 눌리는 칸" 이다.
    card_columns_out: *?maru.chrome.components.sidebar.Columns,
    /// 검색 줄에 그릴 것 — 친 글자와 캐럿(포커스일 때만).
    search_query_in: []const u8,
    search_caret_in: bool,
) !void {
    out.clearRetainingCapacity();
    glyphs.* = 0;
    outside.* = 0;
    card_over_header.* = 0;
    cells_clipped.* = 0;
    cards_visible.* = 0;
    header_h_out.* = 0;
    header_icon_band_out.* = 0;
    header_icon_glyphs.* = 0;
    header_search_glyphs.* = 0;
    header_outside.* = 0;
    if (sidebar_w == 0) return;
    // **사이드바 rect 에서 온다 — 작업영역이 아니다.** 둘은 이제 y 가 다르다: 사이드바는 창 맨
    // 위부터고(타이틀 띠를 포함한다) 작업영역은 띠 아래부터다. 작업영역에서 가져오면 아이콘 줄이
    // 띠 **아래**에 그려져 창 버튼과 다른 줄에 선다(실측 2026-08-25: 종 아이콘 잉크가 y 48–63,
    // 최소화 선은 y 19 였다). 그린 자리와 눌리는 자리의 주인은 `dock_layout` 하나다.
    const top_y = geom.sidebar.y;
    const h = geom.sidebar.h;
    try out.append(allocator, d3d11_cells.solidCell(
        0,
        @floatFromInt(top_y),
        @floatFromInt(sidebar_w),
        @floatFromInt(h),
        cellColor(tk, .surface_bg),
        .{ 0, 0, 0, 0 },
    ));

    // ── 헤더 아이콘 줄 (W8.8⒝) ──────────────────────────────────────────────────────────────
    //
    // **띠가 아니라 사이드바 안이다.** §2m.37 ⒝ 가 정한 모양 — 제목 줄 오른쪽 끝은 캡션 버튼이
    // 가져가고, 사이드바(헤더 포함)는 **그 아래**에 산다(VS Code·파일 탐색기와 같은 모양).
    // macOS 처럼 뒤집지 않는다: 신호등이 없으니 헤더 왼쪽을 비울 이유가 없고, 아이콘은 양쪽 다
    // **헤더 오른쪽 끝**이다.
    //
    // **이 슬라이스는 아이콘 줄까지다.** 검색 줄은 편집 모델이 따로 필요하다 — 그래서 헤더 높이를
    // 한 줄로 둔다. 그러면 `headerHit` 의 검색 밴드가 헤더 밖으로 나가 `.search` 가 안 나온다
    // (그린 것 = 눌리는 것: 안 그렸으니 안 눌린다).
    // **헤더 높이는 먼저 알아야 한다**(카드가 그 아래에서 시작한다). 하지만 **그리기는 나중이다** —
    // 스크롤로 위가 잘린 첫 카드가 헤더 위에 얹히기 때문이다(실측: `card_over_header=12`). 도크가
    // 뷰 바를 내용 뒤에 굽는 것과 같은 이유다.
    const header_cols: u16 = @intCast(sidebar_w / cell_w);
    // **헤더 셀은 잠시 따로 담는다.** 높이는 지금 필요하지만(카드가 그 아래에서 시작한다) **그림은
    // 맨 나중**이어야 한다 — 스크롤로 위가 잘린 첫 카드가 헤더 위에 얹히기 때문이다(실측:
    // `card_over_header=12`). 도크가 뷰 바를 내용 뒤에 굽는 것과 같은 이유다.
    var header_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer header_cells.deinit(allocator);
    // **어느 경로로 나가든 헤더는 그려진다.** 아래에는 조기 반환이 여럿 있고(폭 부족·카드 없음),
    // 그때 헤더까지 사라지면 좁은 창에서 사이드바가 통째로 빈다.
    defer out.appendSlice(allocator, header_cells.items) catch {};
    const header_h = try appendSidebarHeaderCells(
        allocator,
        &header_cells,
        header_cols,
        top_y,
        h,
        sidebar_w,
        cell_w,
        cell_h,
        tk,
        renderer_state,
        builder,
        pipeline,
        atlas_w,
        atlas_h,
        uploaded,
        header_icon_glyphs,
        header_search_glyphs,
        search_query_in,
        search_caret_in,
        header_outside,
        header_drawn,
        header_frame_slot,
        hover_header,
        titlebar_px,
    );
    header_h_out.* = header_h;
    header_icon_band_out.* = if (header_h == 0) 0 else titlebar_px;

    // 카드 하나 — 지금 세션. **줄 수를 여기서 정하고 그 값으로 높이를 얻는다**(그 필드 doc: 호스트가
    // 렌더에 쓰는 줄 수와 같은 값을 실어야 클릭 좌표가 안 갈린다).
    const sb = maru.chrome.components.sidebar;
    const m = sb.Metrics.init(cell_h, cell_h);
    // **카드가 실제로 그리는 줄 수를 쓴다.** 1 로 박아 두면 밴드가 글자보다 짧아져 둘째 줄이 밖으로
    // 나간다(판정 `sidebar_cells_outside` 가 4 를 냈다 — 그 필드 doc 이 예고한 그대로다:
    // "host 가 렌더에 쓰는 줄 수와 같은 값을 실어야 한다").
    if (cards.len == 0) return;
    first_visible.* = 0;
    first_band_y.* = 0;
    partial_out.* = 0;
    active_band_y.* = null;
    // **헤더 아래에서 시작한다** — `slotAt` 도 같은 `header_height_px` 를 받으므로 그린 자리와
    // 눌리는 자리가 안 갈린다. 카드 높이를 **누적**하는 것도 `slotAt` 과 같은 규칙이다(카드마다
    // 줄 수가 달라 고정 나눗셈을 못 쓴다).
    const list_top = top_y + header_h + m.content_pad_v;
    // **목록 셀은 헤더 아래로 잘린다.** 이 지점부터 `out` 에 들어가는 것이 목록이고(헤더 셀은
    // `header_cells` 에 따로 담겨 맨 나중에 붙는다), 나가기 직전에 한 번 자른다. `defer` 를 헤더
    // 것보다 **뒤에** 등록해 LIFO 로 **먼저** 돌게 한다 — 헤더는 잘리면 안 된다.
    const list_cells_start = out.items.len;
    const list_min_y: f32 = @floatFromInt(top_y + header_h);
    defer clipSidebarListCells(out, list_cells_start, list_min_y, card_over_header, cells_clipped);
    // **스크롤: 어느 카드부터 보이나.** `slotAt` 이 쓰는 것과 **같은 누적**이다(카드 높이가 줄 수에서
    // 나오므로 고정 나눗셈을 못 쓴다) — 여기서 다른 식을 쓰면 그린 카드와 눌리는 카드가 갈린다.
    var active_window_index: ?usize = null;
    var first: usize = 0;
    var first_offset: u32 = 0;
    while (first < cards.len) : (first += 1) {
        const h_i = sb.cardHeight(cards[first].lines, m);
        if (first_offset + h_i > scroll_px) break;
        first_offset += h_i;
    }
    if (first >= cards.len) return; // 다 지나갔다(상한이 막아야 하지만 방어)
    first_visible.* = first;
    // 첫 보이는 카드가 위로 잘린 픽셀. 도크의 `origin_shift_px` 와 같은 뜻이다.
    const partial: u32 = scroll_px -| first_offset;
    partial_out.* = partial;

    // **밴드를 카드마다 그린다.** 활성은 진하고, 가리키면 밝아진다.
    //
    // **`row_hover_bg` 다, `tab_hover_bg` 가 아니다.** 토큰 문서가 그 함정을 이미 적어 뒀다 —
    // `tab_hover_bg` 는 배경↔활성 **중간**이라 **활성 카드 위에서는 활성색보다 어두워 호버가
    // 사라진다.** `row_hover_bg` 가 "활성 밴드 위에 겹쳐도 구분되게" 활성보다 한 단계 밝다.
    var band_top = list_top -| partial;
    first_band_y.* = band_top;
    var last_bottom = band_top;
    // **몇 장이 실제로 들어가나.** 밴드는 넘치면 멈추는데 글자를 전부 그리면 목록 밖으로 샌다
    // (실측: 세션 13 개에서 `sidebar_cells_outside=64`). 아래 글자 조립이 이 수만큼만 쓴다.
    var visible: usize = 0;
    for (cards[first..], first..) |c, i| {
        const ch_i = sb.cardHeight(c.lines, m);
        // **위로 잘린 첫 카드는 그린다**(밴드가 헤더 아래에서 잘려 보이는 것이 정상이다).
        // 아래로 넘치는 카드에서 멈춘다.
        if (band_top >= top_y + h) break;
        const hovered = hover_slot != null and hover_slot.? == i;
        // **활성 판정은 여기 한 곳이다.** 밴드(앰버 막대)와 글자 색이 각자 계산하면 창 좌표를
        // 한쪽만 안 옮기는 실수가 난다 — 그 뮤턴트가 판정을 통과했다.
        const is_active = i == active_card;
        if (is_active) active_window_index = i - first;
        if (hovered or is_active) {
            try out.append(allocator, d3d11_cells.solidCell(
                0,
                @floatFromInt(band_top),
                @floatFromInt(sidebar_w),
                @floatFromInt(ch_i),
                cellColor(tk, if (hovered) .row_hover_bg else .tab_active_bg),
                .{ 0, 0, 0, 0 },
            ));
        }
        // 활성 카드의 **좌측 앰버 막대**(chrome-strategy.md U1) — 어느 세션이 활성인지의 신호다.
        // **활성에만 선다**: 전부 그리면 "지금 어느 것" 이라는 질문에 답을 안 하는 셈이다.
        if (is_active) {
            active_band_y.* = band_top;
            try out.append(allocator, d3d11_cells.solidCell(
                0,
                @floatFromInt(band_top),
                3,
                @floatFromInt(ch_i),
                cellColor(tk, .accent_bar),
                .{ 0, 0, 0, 0 },
            ));
        }
        band_top += ch_i;
        last_bottom = band_top;
        visible = i + 1 - first;
    }
    cards_visible.* = visible;
    if (visible == 0) return;
    // ── 카드 글자 (W8.8⒜2) ──────────────────────────────────────────────────────────────────
    //
    // **투영은 이미 있다** — `coretext_frame_builder.buildSidebarDrawList`(이름과 달리 본문에
    // CoreText 참조 0). 이름·브랜치·폴더를 한 카드로 합성한다.
    if (frame_slot.*) |*old_frame| {
        old_frame.deinit(allocator);
        frame_slot.* = null;
    }
    // **글자를 앰버 막대만큼 들여쓴다.** 안 하면 첫 글자가 막대에 잘린다(실측). 값은 chrome
    // 토큰이 소유한다(`space.card_gap_px` + `accent_bar_width_px`) — macOS 가 쓰는 그 산식이다.
    // **spacing 은 색과 무관하다** — 기본 토큰셋에서 읽는다(테마가 간격을 바꾸지 않는다).
    const sp = maru.chrome.Tokens.rich(std.mem.zeroes(maru.chrome.tokens.ThemeColors)).space;
    // **열 배치는 중립이 소유한다**(`chrome.components.sidebar.columns`) — macOS 가 이미 그렇게
    // 쓴다(`sidebarColumns`: *"렌더와 hit-test 가 둘 다 이걸 부르므로 gutter·inset 이 바뀌어도
    // 한쪽만 움직일 수 없다"*).
    //
    // **여기는 손으로 계산하고 있었고, 오른쪽 inset 을 빼먹었다** — 그러면 ✕ 를 중립이 말하는 칸보다
    // 한 칸 오른쪽에 그리게 되고, 중립 `closeButton` 으로 누르면 빗나간다. W8.14 가 그 히트테스트를
    // 처음 쓰면서 드러났다(적대적 검증 전에 **읽어서** 찾았다).
    const layout = maru.chrome.components.sidebar.columns(
        sidebar_w,
        cell_w,
        scrollGutterPx(),
        @as(u32, sp.card_gap_px) + @as(u32, sp.accent_bar_width_px), // 좌측 accent 막대 + 카드 패딩
        sp.card_gap_px, // 우측 카드 패딩
    ) orelse {
        card_cols_out.* = 0;
        card_columns_out.* = null;
        return;
    };
    const indent_cols: u16 = layout.indent_cols;
    // **그리기가 실제로 쓴 칸 수를 낸다.** 판정이 이 값을 스크롤바 자리와 견준다 — 여기서 다시
    // 계산하면 내가 쓴 식을 되읽는 동어반복이라, 거터를 빼는 것을 잊어도 안 움직인다.
    const cols: u16 = indent_cols +| layout.cols;
    card_cols_out.* = cols;
    card_columns_out.* = layout;
    if (cols < indent_cols + 4) return;
    const fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 } };
    const active_fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    // **카드마다 한 항목.** `buildSidebarDrawList` 는 원래 목록을 받는 함수라 여기서 늘리는 것은
    // 배열 셋뿐이다 — 투영 규칙은 그대로다.
    // **보이는 카드만 조립한다** — 밴드가 멈춘 곳 아래로 글자를 내면 사이드바 밖으로 샌다.
    const shown = cards[first..][0..visible];
    const names = try allocator.alloc([]const u8, shown.len);
    defer allocator.free(names);
    const branches = try allocator.alloc([]const u8, shown.len);
    defer allocator.free(branches);
    const paths = try allocator.alloc([]const u8, shown.len);
    defer allocator.free(paths);
    const actives = try allocator.alloc(bool, shown.len);
    defer allocator.free(actives);
    for (shown, 0..) |c, i| {
        names[i] = c.name;
        branches[i] = c.branch;
        paths[i] = c.folder;
        // **밴드 루프가 정한 그 값**을 쓴다(위 주석) — 여기서 다시 계산하지 않는다.
        actives[i] = active_window_index != null and active_window_index.? == i;
    }
    const empty: []const []const u8 = &.{};
    const list = cell_text.buildSidebarDrawList(
        allocator,
        names,
        branches,
        paths,
        empty,
        &.{},
        &.{},
        &.{},
        cols -| indent_cols,
        fg,
        actives,
        empty,
        null,
        0,
        active_fg,
        null,
    ) catch return;
    const frame = renderer_state.buildFrameFromDrawListWithRasterizer(allocator, list, builder.shaper, builder.rasterizer) catch {
        var l = list;
        l.deinit(allocator);
        return;
    };
    frame_slot.* = frame;
    try draw_host.syncAtlasTexture(pipeline, renderer_state, atlas_w, atlas_h);
    uploaded.* += draw_host.uploadFrameRegions(pipeline, frame);

    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 },
        .default_bg = .{ .r = 0x14, .g = 0x19, .b = 0x22 },
    };
    const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, colors);
    defer allocator.free(native);
    // **세로 자리는 중립이 정한다**(`sidebar_glyph_rows.fillOriginY`) — 접는 규칙(`sidebarGlyphRow`)과
    // 한 파일에 있어 갈리지 않는다. macOS 도 같은 함수를 쓴다.
    const rows = try allocator.alloc(maru.chrome.components.sidebar.Row, shown.len);
    defer allocator.free(rows);
    for (shown, 0..) |c, i| rows[i] = .{ .card = .{ .tab = @intCast(first + i), .label = c.name, .active = actives[i], .lines = @intCast(c.lines) } };
    maru.sidebar_glyph_rows.fillOriginY(allocator, native, rows, m);
    // `fillOriginY` 는 **content 상대**다(목록 위 여백부터). 띠와 **헤더**만큼 통째로 내린다 —
    // 밴드와 같은 기준이어야 한다. 헤더를 빼먹었더니 판정이 바로 잡았다(`sidebar_cells_outside=13`).
    // `fillOriginY` 는 **창을 새 목록처럼** 배치한다(첫 카드가 목록 맨 위). 그래서 띠·헤더만큼
    // 내리고 **잘린 만큼 올린다** — 그 둘이 도크의 `origin_shift_px` 와 같은 일을 한다.
    for (native) |*n| n.origin_y = (n.origin_y +| (top_y + header_h)) -| partial;
    try out.ensureUnusedCapacity(allocator, native.len);
    // **판정은 카드 밴드 기준이다.** 사이드바 사각형으로 재면 속 빈다 — 글자가 카드 밖으로 나가도
    // 띠 안이라 0 이 나온다(실측: 행 인코딩을 안 지운 뮤턴트가 그렇게 통과했다).
    const x1: f32 = @floatFromInt(sidebar_w);
    // **판정 기준은 목록 전체의 밴드 구간**이다 — 카드가 여럿이면 한 장짜리 사각형으로는 못 잰다.
    const band_y0: f32 = @floatFromInt(list_top -| partial);
    const band_y1: f32 = @floatFromInt(last_bottom);
    for (native) |n| {
        var c = n;
        // **행 번호를 0 으로 만든다.** `cellFromNative` 는 `origin_y + row*cell_h` 로 자리를 만드는데,
        // 사이드바 셀의 `row` 는 격자 행이 아니라 **슬롯·줄 인코딩**이다(`sidebar_glyph_rows`).
        // 안 지우면 그 인코딩이 픽셀로 곱해져 글자가 카드 한참 아래에 그려진다(실측: 카드 밴드가
        // y=14~58 인데 글자가 y=189·229 였다). `fillOriginY` 가 이미 최종 y 를 넣어 뒀다.
        c.row = 0;
        c.col +|= indent_cols;
        const cell = win32_terminal.cellFromNative(c, cell_w, cell_h, atlas_w.*, atlas_h.*);
        // **글자가 사이드바 사각형을 벗어나면 안 된다** — 벗어나면 터미널 위에 얹힌다.
        if (cell.rect[0] < 0 or cell.rect[0] + cell.rect[2] > x1 or
            cell.rect[1] < band_y0 or cell.rect[1] + cell.rect[3] > band_y1) outside.* += 1;
        glyphs.* += 1;
        out.appendAssumeCapacity(cell);
    }
}

/// 목록 셀 구간을 헤더 아래로 자른다 — 통째로 위에 있던 셀은 **버리고 그 수를 센다**.
///
/// 그 수가 `card_over_header` 다. 예전에는 "맨 위에 있을 때만" 세는 값이라 **굴린 상태를 아무도 안
/// 재고 있었다**(그래서 겹침이 그대로 나갔다). 이제는 자른 뒤라 **어느 스크롤에서도 0** 이어야 한다.
fn clipSidebarListCells(
    out: *std.ArrayList(d3d11_cells.Cell),
    start: usize,
    min_y: f32,
    /// 자른 **뒤에도** 헤더 위에 남은 셀 수 — 어느 스크롤에서도 **0 이어야 한다**.
    violations: *usize,
    /// **잘린**(버려진 것이 아니라 위가 깎인) 셀 수. 0 이면 위 판정이 아무것도 안 물었거나,
    /// 반쯤 걸친 줄을 **통째로 버리고** 있다는 뜻이다 — 그러면 맨 윗줄이 통째로 사라진다.
    clipped: *usize,
) void {
    if (start >= out.items.len) return;
    var w = start;
    for (out.items[start..]) |c| {
        if (d3d11_cells.clipCellTop(c, min_y)) |cc| {
            if (cc.rect[1] != c.rect[1]) clipped.* += 1;
            if (cc.rect[1] < min_y - 0.01) violations.* += 1;
            out.items[w] = cc;
            w += 1;
        }
    }
    out.items.len = w;
}

/// 헤더 아이콘 줄을 셀로 낸다 — **차지한 높이(px)** 를 돌려준다(0 이면 안 그렸다).
///
/// **글리프 조립은 공유 모듈이 소유한다**(`cell_text.appendSidebarHeaderIcons`) — 열과 배지 규칙이
/// macOS 와 한 곳이라 두 화면이 안 갈린다. 여기가 하는 일은 그 셀을 아틀라스에 굽고 픽셀 자리를
/// 주는 것뿐이다.
fn appendSidebarHeaderCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    cols: u16,
    top_y: u32,
    /// 사이드바가 쓸 수 있는 세로 길이. **헤더가 이보다 높으면 안 그린다** — 안 넘기던 판에서는
    /// `header_outside` 가 헤더 자신을 기준으로 재서 이 경우를 **구조적으로 못 봤다**.
    avail_h: u32,
    sidebar_w: u32,
    cell_w: u32,
    cell_h: u32,
    tk: *const maru.chrome.Tokens,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    icon_glyphs: *usize,
    search_glyphs: *usize,
    search_query: []const u8,
    search_caret: bool,
    outside: *usize,
    drawn: *DrawnHeaderIcons,
    frame_slot: *?maru.renderer.RenderFrame,
    hover_header: ?maru.chrome.components.sidebar.HeaderRegion,
    /// 아이콘 줄이 쓰는 띠 높이. **창의 타이틀 띠와 같은 값**이다 — 그래야 아이콘이 최소화·최대화
    /// 버튼과 같은 줄에 선다(사용자 지적 2026-08-25, `dock_layout.sidebarOf` 의 doc 이 근거를 갖는다).
    /// 여기서 `cell_h * 2` 로 다시 유도하지 않는다: 창은 `max(cell_h * 2, 32)` 라 작은 폰트에서
    /// 갈리고, 그러면 아이콘 줄만 띠 위로 떠 버린다.
    icon_band_px: u32,
) !u32 {
    drawn.clear();
    // 헤더 = 아이콘 밴드(= 타이틀 띠) + 검색 줄 하나. 아이콘을 1.7× 로 굽는 이상 한 줄짜리 밴드로는
    // 넘치는데(실측: `header_outside=4`), 띠가 이미 두 줄 이상이라 그 자리가 그대로 맞는다.
    const header_h: u32 = icon_band_px +| cell_h;
    // 카드가 쓰는 규칙과 같다(`top + card_h > h` 면 안 그린다) — 반쯤 걸친 아이콘보다 없는 편이 낫다.
    if (header_h > avail_h) return 0;
    if (frame_slot.*) |*old| {
        old.deinit(allocator);
        frame_slot.* = null;
    }
    var cells: std.ArrayList(maru.renderer.DrawCell) = .empty;
    defer cells.deinit(allocator);
    const fg_rgb = tk.get(.surface_fg);
    const fg: maru.terminal.Color = .{ .rgb = .{ .r = fg_rgb.r, .g = fg_rgb.g, .b = fg_rgb.b } };
    // 알림 수는 아직 0 이다 — Windows 앱에 알림 모델이 안 붙었다(⒞). **배지 규칙은 이미 공유
    // 모듈에 있으므로** 그 수만 넘기면 그날 바로 뜬다.
    const drew = cell_text.appendSidebarHeaderIcons(allocator, &cells, cols, fg, 0) catch return 0;
    if (!drew) return 0;
    // 가리킨 아이콘 뒤에 밝은 판을 깐다 — 아이콘 색은 안 바꾼다. 예전에 호버 아이콘을
    // `sidebar_active` 로 재색칠했다가, 그 색이 밝은 전경이 아니라 **어두운 밴드색**인 테마에서
    // 아이콘이 오히려 어두워졌다(공유 모듈 주석이 그 실패를 적어 뒀다).
    if (hover_header) |hr| hover: {
        const sb_h = maru.chrome.components.sidebar;
        const hover_col: u32 = switch (hr) {
            .toggle_sidebar => sb_h.headerIconCol(.toggle_sidebar, cols),
            .view_options => sb_h.headerIconCol(.view_options, cols),
            .new_workspace => sb_h.headerIconCol(.new_workspace, cols),
            .notifications => cell_text.sidebarBellCol(cols),
            .search, .none => break :hover,
        };
        const hb = tk.get(.tab_hover_bg);
        try out.append(allocator, d3d11_cells.solidCell(
            @floatFromInt(hover_col *| cell_w),
            @floatFromInt(top_y + (icon_band_px -| cell_h) / 2),
            @floatFromInt(cell_w *| 2),
            @floatFromInt(cell_h),
            d3d11_cells.colorFromArgb(0xFF000000 | (@as(u32, hb.r) << 16) | (@as(u32, hb.g) << 8) | hb.b),
            .{ 0, 0, 0, 0 },
        ));
    }
    // **검색 줄도 그린다.** `headerHit` 이 아래 밴드를 `.search` 로 판정하므로 안 그리면
    // "그린 것 = 눌리는 것" 이 깨진다. 친 글자와 캐럿은 호출자가 준다(W8.15).
    const muted_rgb = tk.get(.muted_fg);
    const typed_rgb = tk.get(.surface_fg);
    // **grapheme pool 을 준다** — 검색어가 cluster 경로로 나가므로 base 뒤 코드포인트(NFD 한글 V·T,
    // 결합 악센트)를 실을 곳이 있어야 한다. 없으면 그 글자들이 통째로 빠진다.
    var search_pool: std.ArrayList(u32) = .empty;
    cell_text.appendSidebarSearchRow(
        allocator,
        &cells,
        1,
        cols,
        .{ .rgb = .{ .r = muted_rgb.r, .g = muted_rgb.g, .b = muted_rgb.b } },
        search_query,
        .{ .rgb = .{ .r = typed_rgb.r, .g = typed_rgb.g, .b = typed_rgb.b } },
        search_caret,
        &search_pool,
    ) catch {};
    // **글리프가 실제로 앉은 열**을 여기서 집는다(정체는 codepoint 가 준다). 아래 판정이 이것을
    // `headerHit` 에 되먹인다 — 그러면 그리기 쪽만 어긋나도 잡힌다.
    for (cells.items) |c| if (cell_text.isSidebarHeaderIcon(c.codepoint)) drawn.append(.{ .col = c.col, .codepoint = c.codepoint });

    const list = maru.renderer.DrawList{
        .size = .{ .cols = cols, .rows = 2 },
        .cursor = .{ .row = 0, .col = 0 },
        .dirty = null,
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try allocator.alloc(maru.renderer.DrawOverlay, 0),
        .grapheme_pool = try search_pool.toOwnedSlice(allocator),
    };
    // ── 아이콘을 셀보다 크게 굽는다 (1.7×) ─────────────────────────────────────────────────
    //
    // **셀 크기로 굽고 GPU 에서 늘리면 흐려진다.** 그래서 아틀라스 슬롯을 목표 픽셀로 키워 **그
    // 크기로 직접 래스터**한다 — 1.7× 텍스처가 1.7× quad 에 1:1 로 들어간다. 배율은
    // `chrome.ui.icon` 이, 대상 목록은 `cell_text.isSidebarHeaderIcon` 이 소유한다(macOS 와 한 곳).
    //
    // 셰이핑과 래스터 사이를 가르는 이음매는 **중립이 이미 준다**(`buildGlyphRunList` →
    // `buildFrameFromGlyphRunListWithRasterizer`) — macOS 가 `shapeOnly` 로 쓰는 그 자리다.
    var glyph_runs = maru.renderer.glyph_layout.buildGlyphRunList(allocator, list, renderer_state.text_config, builder.shaper) catch {
        var l = list;
        l.deinit(allocator);
        return 0;
    };
    defer glyph_runs.deinit(allocator);
    const icon_scale = maru.chrome.ui.icon;
    const rw: u16 = @intCast(@min(icon_scale.cellRasterExtentPx(cell_w), @as(u32, std.math.maxInt(u16))));
    const rh: u16 = @intCast(@min(icon_scale.cellRasterExtentPx(cell_h), @as(u32, std.math.maxInt(u16))));
    if (rw > 0 and rh > 0) {
        for (glyph_runs.glyphs) |*g| {
            if (!cell_text.isSidebarHeaderIcon(g.codepoint)) continue;
            g.cache_key.raster_width_px = rw;
            g.cache_key.raster_height_px = rh;
        }
    }
    const frame = renderer_state.buildFrameFromGlyphRunListWithRasterizer(allocator, list, glyph_runs, builder.rasterizer) catch {
        var l = list;
        l.deinit(allocator);
        return 0;
    };
    frame_slot.* = frame;
    // **여기서 올린다**(§2m.32) — 프레임의 업로드 목록은 프레임과 함께 죽는다. 버리고 나서 올리면
    // 공용 CPU 캐시가 "있다" 고 표시해 아무도 다시 안 올린다.
    try draw_host.syncAtlasTexture(pipeline, renderer_state, atlas_w, atlas_h);
    uploaded.* += draw_host.uploadFrameRegions(pipeline, frame);

    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = fg_rgb.r, .g = fg_rgb.g, .b = fg_rgb.b },
        .default_bg = .{ .r = 0, .g = 0, .b = 0 },
    };
    const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, colors);
    defer allocator.free(native);
    const x1: f32 = @floatFromInt(sidebar_w);
    const y0: f32 = @floatFromInt(top_y);
    // **사이드바 바닥을 기준으로 잰다.** 헤더 높이로 재면 자기 자신과 견주는 꼴이라 아무것도 못 잡는다.
    const y1: f32 = @floatFromInt(top_y + @min(header_h, avail_h));
    try out.ensureUnusedCapacity(allocator, native.len);
    for (native) |n| {
        var c = n;
        // 헤더는 **한 줄**이라 행이 0 이고, 세로 자리는 `origin_y` 하나로 정해진다(카드처럼 슬롯
        // 인코딩을 쓰지 않는다).
        // **줄마다 자리가 다르다.** 아이콘 줄은 **아이콘 밴드 안에서 세로 중앙**이어야 1.7× 글리프가
        // 밴드를 안 넘친다(`headerHit` 이 `icon_top = (search_top - ch) / 2` 로 클릭 사각형을 잡는
        // 그 자리와 같다). 검색 줄은 그 밴드 바로 아래다.
        const is_icon_row = c.row == 0;
        c.origin_y = top_y + if (is_icon_row) (icon_band_px -| cell_h) / 2 else icon_band_px;
        c.row = 0;
        var cell = win32_terminal.cellFromNative(c, cell_w, cell_h, atlas_w.*, atlas_h.*);
        // **quad 도 같은 배율로 키운다** — 텍스처만 키우면 1.7× 그림이 1칸에 눌려 들어간다. 중심을
        // 고정한 채 넓힌다(열은 그대로라 히트테스트와 안 갈린다).
        if (std.math.cast(u21, c.codepoint)) |cp| if (cell_text.isSidebarHeaderIcon(cp)) {
            // **한 셀을 키운다 — 그 글리프가 몇 칸을 차지하든.** 종은 EAW 2칸이라 quad 가 2셀인데,
            // 아틀라스 슬롯은 한 셀 ×1.7 로 구웠다. 그대로 곱하면 가로만 3.4셀이 되어 **찌그러진다**
            // (실측: 종이 납작한 아치로 보였다). macOS 도 2칸 위에 1.7셀 폭으로 그린다 — 중심은
            // 원래 칸들의 한가운데(그쪽의 `-0.5 nudge`와 같은 자리).
            const scale = @as(f32, @floatFromInt(icon_scale.cell_raster_scale_milli)) / 1000.0;
            const sw = @as(f32, @floatFromInt(cell_w)) * scale;
            const sh = @as(f32, @floatFromInt(cell_h)) * scale;
            const cx = cell.rect[0] + cell.rect[2] / 2;
            const cy = cell.rect[1] + cell.rect[3] / 2;
            cell.rect[0] = cx - sw / 2;
            cell.rect[1] = cy - sh / 2;
            cell.rect[2] = sw;
            cell.rect[3] = sh;
        };
        // **구운 크기와 그린 크기를 함께 싣는다** — 둘 중 하나만 커도 흐려지는데, 개수·자리 판정은
        // 그것을 못 본다.
        if (std.math.cast(u21, c.codepoint)) |cp| {
            for (drawn.items[0..drawn.len]) |*g| {
                if (g.codepoint != cp) continue;
                g.atlas_h = c.atlas_height_px;
                g.quad_h = cell.rect[3];
                g.atlas_w = c.atlas_width_px;
                g.quad_w = cell.rect[2];
                g.quad_y = cell.rect[1];
            }
        }
        if (cell.rect[0] < 0 or cell.rect[0] + cell.rect[2] > x1 or
            cell.rect[1] < y0 or cell.rect[1] + cell.rect[3] > y1) outside.* += 1;
        if (is_icon_row) icon_glyphs.* += 1 else search_glyphs.* += 1;
        out.appendAssumeCapacity(cell);
    }
    return header_h;
}

/// 호버 밴드가 활성 밴드보다 **밝은가**. 토큰 문서가 정한 규칙이고, 어기면 호버가 화면에서 사라진다.
fn hoverIsBrighter(tk: *const maru.chrome.Tokens) bool {
    const a = tk.get(.tab_active_bg);
    const h = tk.get(.row_hover_bg);
    const la: u32 = @as(u32, a.r) * 299 + @as(u32, a.g) * 587 + @as(u32, a.b) * 114;
    const lh: u32 = @as(u32, h.r) * 299 + @as(u32, h.g) * 587 + @as(u32, h.b) * 114;
    return lh > la;
}

/// 헤더에 실제로 그려진 아이콘 하나 — **정체는 codepoint, 자리는 열**이다.
const DrawnHeaderIcon = struct {
    col: u16,
    codepoint: u21,
    /// 아틀라스에 **구워진** 높이(px). 셀보다 커야 1.7× quad 에 1:1 로 들어간다 — 셀 크기로 굽고
    /// 늘리면 흐려진다(그것을 숫자로 잡는 유일한 자리).
    atlas_h: u32 = 0,
    /// 화면에 **그려진** 높이(px). 슬롯만 키우고 quad 를 안 키우면 1.7× 그림이 한 칸에 눌린다.
    quad_h: f32 = 0,
    /// 가로도 함께 싣는다 — **높이만 보면 찌그러진 것을 못 잡는다.** EAW 2칸 글리프(종)의 quad 를
    /// 칸 수까지 곱해 키우면 세로는 맞고 가로만 2배가 되는데, 그때도 높이 판정은 초록이었다(실측).
    atlas_w: u32 = 0,
    quad_w: f32 = 0,
    /// 화면에 **그려진 세로 자리**. 아이콘 줄이 타이틀 띠 **안**에 있는지의 유일한 관측점이다 —
    /// 개수·폭·높이 판정은 그것을 못 본다(실측 2026-08-25: 띠 아래에 그려지고 있는데 `header_ok`
    /// 를 비롯한 판정이 **전부 초록**이었다. 픽셀을 세어 보고서야 드러났다).
    quad_y: f32 = 0,
};

/// 그려진 것들의 작은 고정 목록. 할당을 안 하려고 배열로 둔다(판정 전용이고 넷을 넘길 일이 없다).
const DrawnHeaderIcons = struct {
    items: [8]DrawnHeaderIcon = undefined,
    len: usize = 0,
    fn clear(self: *DrawnHeaderIcons) void {
        self.len = 0;
    }
    fn append(self: *DrawnHeaderIcons, v: DrawnHeaderIcon) void {
        if (self.len >= self.items.len) return;
        self.items[self.len] = v;
        self.len += 1;
    }
    fn slice(self: *const DrawnHeaderIcons) []const DrawnHeaderIcon {
        return self.items[0..self.len];
    }
};

/// 창 크기가 바뀌면 **모든 세션**의 격자와 PTY 를 함께 바꾼다.
///
/// **활성만 바꾸면 안 된다**: 배경 세션은 옛 격자를 들고 있다가 전환하는 순간 어긋난 화면을 낸다.
/// 그 실패를 `sessions_wrong_size` 가 잰다(고치기 전 실측: 1).
///
/// 실패한 세션은 **건너뛴다** — 하나가 안 됐다고 나머지까지 옛 크기로 두면 더 나쁘다.
fn resizeAllSessions(
    runtime: *maru.app.SurfaceRuntime,
    sessions: []const *WinSession,
    size: maru.terminal.Size,
    io: std.Io,
) void {
    for (sessions) |s| runtime.resize(s.surface.id, size, io) catch {};
}

/// 활성 표면의 격자 지문 — **화면이 어느 세션을 보고 있는지**의 증거.
///
/// 셀의 codepoint 를 섞는다. 두 셸이 각자 프롬프트를 찍으므로 다른 세션이면 값이 다르다.
/// 표면 하나의 격자 지문과 잉크 셀 수.
fn surfaceGridStats(io: std.Io, s: *maru.session.surface.Surface) struct { digest: u64, ink: usize } {
    s.lockCore(io);
    defer s.unlockCore(io);
    var h: u64 = 1469598103934665603;
    var ink: usize = 0;
    for (s.core.screen.cells) |c| {
        h ^= @as(u64, c.codepoint);
        h *%= 1099511628211;
        if (c.codepoint != 0 and c.codepoint != ' ') ink += 1;
    }
    return .{ .digest = h, .ink = ink };
}

fn activeGridDigest(io: std.Io, app_window: *maru.session.window.AppWindow) u64 {
    const active = app_window.active() orelse return 0;
    // **코어 락 아래에서 읽는다** — 리더 스레드가 같은 코어에 쓰고 있다(io-render-threading PR3).
    // 래퍼를 쓴다: `core_mutex` 를 직접 잡는 것은 `check-boundaries` 가 막는다(재진입 검출을 우회한다).
    active.lockCore(io);
    defer active.unlockCore(io);
    var h: u64 = 1469598103934665603;
    for (active.core.screen.cells) |c| {
        h ^= @as(u64, c.codepoint);
        h *%= 1099511628211;
    }
    return h;
}

/// 한 창이 들 수 있는 세션 수의 상한.
///
/// **왜 상한을 두나**: ＋ 는 연타할 수 있고 세션마다 PTY·리더 스레드가 하나씩 붙는다.
///
/// **이 상한이 "다 보인다" 를 보장하지는 않는다**(처음에 그렇게 적었는데 틀렸다). 보이는 카드 수는
/// **창 높이**가 정한다 — 1000×640 에서 두 줄짜리 카드는 여덟 장쯤이다(실측: 세션 13 개에서 여덟
/// 장만 그려졌다). 나머지는 목록에 있지만 화면에 없고 누를 수도 없다. 그것을 조용히 두지 않으려고
/// 스모크가 `cards_visible` 을 함께 낸다 — 사이드바 스크롤이 붙으면 사라지는 한계다
/// (`slotAt` 은 이미 `scroll_offset_px` 를 받는다. 지금은 0 을 넘긴다).
/// 상태바가 한 프레임에 담는 항목 상한. 지금 Windows 가 낼 수 있는 것은 좌측 둘(브랜치·경로)이다.
const max_status_bar_items: usize = 4;

const max_win_sessions: usize = 16;

/// 세션 목록 → 카드 목록. **세션이 늘거나 줄면 다시 부른다** — 안 부르면 사이드바가 옛 목록을 그린다.
/// 사이드바가 **굵게 그릴 칸**. 활성이 터미널이면 그 탭 번호이고, 파일이면 세션 수만큼 밀린다 —
/// 이 산수가 목록을 짓는 곳과 갈리면 누른 칸과 굵은 칸이 어긋난다.
fn sidebarActiveSlot(cards: []const SidebarCard, view: ActiveView) usize {
    for (cards, 0..) |c, i| {
        const hit = switch (view) {
            .terminal => |t| c.source == .session and c.source.session == t,
            .file => |f| c.source == .file and c.source.file == f,
        };
        if (hit) return i;
    }
    // **안 보이는 것을 가리키게 둔다.** 검색이 활성 카드를 걸러내면 "굵게 그릴 칸이 없다" 가 맞는
    // 답이다 — 0 을 내면 엉뚱한 카드에 앰버 막대가 선다.
    return cards.len;
}

/// 사이드바 목록 = **세션 다음에 연 파일**. 순서가 곧 슬롯 번호이고, 클릭 라우팅이 그 경계를
/// `sessions.len` 으로 가른다 — 두 곳이 다른 순서를 쓰면 누른 칸과 열리는 것이 갈린다.
/// 카드가 검색어에 걸리나. **빈 검색어는 전부 통과**한다 — 검색을 안 켠 것과 "아무것도 안 걸렸다" 는
/// 다른 사실이고, 빈 것을 필터로 치면 목록이 통째로 사라진다.
///
/// 이름과 부제(폴더·경로) 둘 다 본다 — 같은 파일명이 여러 폴더에 있을 때 경로로 가르는 것이
/// 카드 둘째 줄을 경로로 둔 이유다(W8.13).
fn cardMatchesQuery(name: []const u8, subtitle: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    return asciiContainsIgnoreCase(name, query) or asciiContainsIgnoreCase(subtitle, query);
}

/// **대소문자를 무시하되 ASCII 만**이다. 한글에는 대소문자가 없어 그대로 비교되고, 그리스·키릴의
/// 접기까지 하려면 유니코드 케이스 표가 필요하다 — 그것은 중립이 아직 안 가진 것이라 여기서
/// 지어내지 않는다(한계로 적는다).
fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) continue :outer;
        }
        return true;
    }
    return false;
}

fn refreshSidebarCards(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(SidebarCard),
    sessions: []const *WinSession,
    files: []const OpenFile,
    folder: []const u8,
    query: []const u8,
) !void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(allocator, sessions.len + files.len);
    for (sessions, 0..) |s, si| {
        if (!cardMatchesQuery(s.label(), folder, query)) continue;
        out.appendAssumeCapacity(.{
            .name = s.label(),
            .branch = "",
            .folder = folder,
            .lines = if (folder.len > 0) 2 else 1,
            .source = .{ .session = si },
        });
    }
    for (files, 0..) |*f, fi| {
        if (!cardMatchesQuery(f.name(), f.path, query)) continue;
        // **둘째 줄은 폴더가 아니라 경로다** — 파일 카드에서 알고 싶은 것은 "어느 폴더 창인가" 가
        // 아니라 "이 파일이 어디 것인가" 다. 같은 이름이 여러 폴더에 있을 때 그것만이 가른다.
        out.appendAssumeCapacity(.{
            .name = f.name(),
            .branch = "",
            .folder = f.path,
            .lines = 2,
            .source = .{ .file = fi },
        });
    }
}

/// 트리 행 하나를 펼치거나 접고 **스캔은 제출까지만** 한다 — 행 클릭이 하는 일.
///
/// **트리는 lazy 다**(`toggleDirectory` 의 doc): 사용자가 펼친 그 순간에 읽는다.
///
/// 돌려주는 값: 행 목록이 바뀌었나(= 다시 그려야 하나).
///
/// **결과를 여기서 기다리지 않는다.** 예전에는 400 회까지 `sleep(1ms)` 로 돌며 기다렸는데, 그동안
/// 창이 통째로 멈춘다 — 큰 폴더나 느린 디스크에서 눈에 띈다(§2m.55 가 그것을 한계로 적어 뒀다).
/// 받는 일은 루프가 매 프레임 하는 `drainTreeScan` 이 한다.
///
/// **접기는 즉시 반영된다** — 요청이 안 생기므로 기다릴 것도 없다.
fn toggleTreeRow(
    allocator: std.mem.Allocator,
    tree: *maru.session.file_tree.Tree,
    backend: ?*file_tree_backend.Backend,
    rows: *std.ArrayList(maru.session.file_tree.Row),
    root_path: []const u8,
    path: []const u8,
    /// 이 토글이 스캔을 **제출했는지**. 접기는 제출하지 않으므로 비동기 판정은 이것을 봐야 한다.
    submitted_out: ?*bool,
) bool {
    _ = tree.toggleDirectory(path) catch return false;
    if (backend) |b| {
        while (tree.takeScanRequest()) |req| {
            if (!b.submit(req, 0)) {
                allocator.free(req);
                break;
            }
            if (submitted_out) |o| o.* = true;
        }
    }
    tree.buildRows(allocator, &.{.{ .path = root_path, .active = true }}, rows) catch return false;
    // **아이콘 종류를 다시 채운다** — 새 행에는 분류가 안 들어 있다(§2m.42 가 그 실패를 겪었다).
    cell_text.classifyFileTreeRows(rows.items);
    return true;
}

/// 와 있는 스캔 결과를 **전부** 받아 트리에 반영한다. 행이 바뀌었으면 `true`.
///
/// 루프가 매 프레임 부른다. **하나만 받고 끝내지 않는다** — 한 프레임에 여러 폴더가 돌아올 수 있고,
/// 남겨 두면 그 결과가 다음 프레임까지 안 보인다.
fn drainTreeScan(
    allocator: std.mem.Allocator,
    io: std.Io,
    tree: *maru.session.file_tree.Tree,
    backend: ?*file_tree_backend.Backend,
    rows: *std.ArrayList(maru.session.file_tree.Row),
    root_path: []const u8,
) bool {
    const b = backend orelse return false;
    var applied = false;
    while (b.takeResult()) |taken| {
        var result = taken;
        defer result.deinit(allocator, io);
        if (!result.ok) continue;
        var inputs: std.ArrayList(maru.session.file_tree.EntryInput) = .empty;
        defer inputs.deinit(allocator);
        for (result.entries.items) |e|
            inputs.append(allocator, .{ .name = e.name, .kind = e.kind, .identity = e.identity }) catch break;
        tree.applySnapshotWithIdentity(result.path, result.identity, inputs.items) catch continue;
        applied = true;
    }
    if (!applied) return false;
    tree.buildRows(allocator, &.{.{ .path = root_path, .active = true }}, rows) catch return false;
    cell_text.classifyFileTreeRows(rows.items);
    return true;
}

/// 에이전트 세션 이력을 한 번 훑어 **도크 항목**으로 만든다(W8.5b⒝).
///
/// **전 구간이 이미 중립이다** — 스캔은 `agent_session_archive_backend`(네이티브 참조 0, `home` 만
/// 받는다), 묶기는 `agent_session_archive_view.build`, 항목 타입은 컴포넌트의 것이다. Windows 가
/// 하는 일은 부르는 순서와 문자열 몇 개를 만드는 것뿐이다.
///
/// **arena 에 담는다.** 카드가 가리키는 제목·요약·메타 문자열은 프레임보다 오래 살아야 하고, 개별
/// `free` 를 늘어놓으면 하나만 빠뜨려도 스캔마다 샌다.
///
/// macOS 의 `buildAgentSessionDockItems` 와 **모양이 겹치지만 지금 빼지 않는다** — 그쪽은 인라인
/// 상세·focus-live·가상화 창을 함께 다루고 여기는 목록 전체를 한 번 만든다. 규칙이 실제로 둘이 되면
/// 그때 뺀다(`scm_items.zig` 가 그렇게 나왔다).
/// UTF-8 경계에서 자른 앞부분. **바이트로 자르면 반쪽 글자가 남아** 어떤 문자열에서도 못 찾는다 —
/// 한글·이모지 제목이 전부 "안 그려졌다" 로 보인다.
fn codepointPrefix(s: []const u8, max_bytes: usize) []const u8 {
    // **안 잘렸으면 손대지 않는다.** 잘 만들어진 문자열은 마지막 바이트가 이어지는 바이트인 것이
    // 정상인데(한글·이모지가 그렇다), 그것을 잘린 것으로 보고 벗기면 **멀쩡한 끝 글자가 사라진다** —
    // 세 바이트짜리 한글 제목이면 남는 것이 0 이라 아예 안 세어진다.
    if (s.len <= max_bytes) return s;
    var end = max_bytes;
    while (end > 0 and (s[end - 1] & 0xC0) == 0x80) end -= 1;
    if (end > 0 and (s[end - 1] & 0x80) != 0) end -= 1;
    return s[0..end];
}

/// `scan` 은 **이 함수가 끝나면 버려지는** arena 다(훑는 동안 나오는 레코드·투영이 여기 쌓인다).
/// `persist` 는 앱 수명 arena — `out` 의 항목이 가리키는 문자열만 이쪽으로 **복사**한다.
/// 목록이 비는 이유 가운데 **그 기계의 사실**인 것들. 나머지(`scan_timeout` 등)는 결함이다.
fn agentListBenign(reason: []const u8) bool {
    return reason.len == 0 or
        std.mem.eql(u8, reason, "no_history") or
        std.mem.eql(u8, reason, "no_home");
}

/// 목록의 **첫 카드**가 가리키는 레코드 번호. 정렬이 뒤집혔는지의 관측점이다.
fn agentFirstCardIdentity(items: []const maru.chrome.components.session_dock.types.Item) ?u64 {
    for (items) |it| switch (it) {
        .card => |c| return c.identity,
        else => {},
    };
    return null;
}

/// `n` 번째 **그룹**이 목록의 몇 번 항목인가. 그룹과 카드가 섞여 있으므로 그룹만 센다.
fn agentFirstGroupIndexAtOrAfter(items: []const maru.chrome.components.session_dock.types.Item, n: usize) ?usize {
    var seen: usize = 0;
    for (items, 0..) |it, idx| switch (it) {
        .group => {
            if (seen == n) return idx;
            seen += 1;
        },
        else => {},
    };
    return null;
}

/// 그려진 목록 항목 하나의 사각형 — **published tree 가 준 자리**다.
///
/// **손으로 고른 좌표를 쓰지 않는다.** 배치가 바뀌면 그 좌표는 엉뚱한 곳을 가리키는데 판정은
/// 그대로 초록이다 — 이 포트에서 그 부류를 여러 번 겪었다. 노드 id 는 `NodeIds.item(index)` 이고
/// 그 번호는 **투영된 목록의 인덱스**다(그 파일의 주석: *"Every projected list item gets an
/// eight-id lane"*).
fn agentItemRect(built: *const agent_surface.Built, index: usize) ?maru.chrome.ui.layout.UiRect {
    const id = maru.chrome.components.session_dock.build.NodeIds.item(index);
    for (built.frame.tree.entries) |e| {
        if (e.id == id) return e.rect;
    }
    return null;
}

/// 스캔이 끝난 뒤에도 남는 **카드 재료**. 재투영(그룹 접기)이 목록을 다시 만들 때 이것만 있으면 된다 —
/// 레코드 원본은 스캔 arena 와 함께 사라진다.
///
/// **왜 레코드 인덱스로 잡나**: 투영이 카드를 `record_index` 로 가리키고(`archive_view.Entry.card`),
/// 그 번호는 접기·펼치기로 안 바뀐다. 목록 위치로 잡으면 그룹을 접는 순간 전부 밀린다.
const AgentCard = struct {
    provider: maru.chrome.components.session_dock.types.Provider,
    title: []const u8,
    summary: []const u8,
    messages: []const u8,
    age: []const u8,
    model: []const u8,
};

/// 재투영에 필요한 것 전부. 문자열은 전부 앱 수명 arena 소유다.
const AgentArchive = struct {
    view_items: []maru.session.agent_session_archive_view.Item = &.{},
    cards: []AgentCard = &.{},
    /// 접힌 그룹의 키(= cwd). **키 문자열이다** — 투영이 그것으로 접기를 판정한다(`build` 의 셋째 인자).
    /// 인텐트는 `u64` 로 오지만 그것은 **그 순간의 그룹 번호**라, 목록이 바뀌면 다른 그룹을 가리킨다.
    collapsed: std.ArrayList([]const u8) = .empty,
    /// 정렬 방향. **스캔 순서는 늘 최신 우선**이고(그 백엔드의 계약) 이 값은 **보여 줄 방향**만
    /// 정한다 — `oldest_first` 면 재투영이 뒤집힌 순서로 짓는다.
    sort: maru.chrome.components.session_dock.types.SortOrder = .newest_first,
    /// 지금 걸러 보고 있는 것. **투영 입력만 좁힌다** — `view_items`·`cards` 는 그대로 두므로
    /// record index 로 잡은 정체가 안 흔들린다(§2m.75 의 사이드바와 다른 점).
    query: []const u8 = "",

    fn isCollapsed(self: *const AgentArchive, key: []const u8) bool {
        for (self.collapsed.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }
};

/// 투영 → 화면 항목. **접기 상태를 반영해 다시 만든다.**
///
/// `scratch` 는 이 호출에서만 사는 arena(투영이 거기 쌓인다), `persist` 는 항목이 가리키는 문자열의
/// 주인이다 — 다만 문자열은 이미 `AgentArchive` 가 들고 있으므로 여기서는 **빌려 쓴다**.
fn projectAgentItems(
    scratch: std.mem.Allocator,
    persist: std.mem.Allocator,
    archive: *const AgentArchive,
    out: *std.ArrayList(maru.chrome.components.session_dock.types.Item),
) !void {
    out.clearRetainingCapacity();
    if (archive.view_items.len == 0) return;
    // **뒤집는 것은 투영 앞이다.** 투영이 "첫 등장 순서" 로 그룹을 만들므로(그 함수의 주석), 뒤에서
    // 항목만 뒤집으면 그룹 머리와 카드가 어긋난다 — 그룹 순서까지 함께 뒤집혀야 한다.
    const ordered: []const maru.session.agent_session_archive_view.Item = switch (archive.sort) {
        .newest_first => archive.view_items,
        .oldest_first => blk: {
            const rev = try scratch.alloc(maru.session.agent_session_archive_view.Item, archive.view_items.len);
            for (archive.view_items, 0..) |vi, idx| rev[archive.view_items.len - 1 - idx] = vi;
            break :blk rev;
        },
    };
    // ── 검색어로 거른다 (W8.15) ────────────────────────────────────────────────────────────
    //
    // **중립 투영은 안 거른다**(`build` 가 질의를 안 받는다) — 무엇이 걸리는가는 호스트의 판단이라
    // 여기서 입력을 좁힌다.
    //
    // **정체가 안 흔들린다.** 카드 identity 는 목록 위치가 아니라 **record index** 다(`build` 가
    // `.card = record_index` 를 낸다) — 걸러도 클릭이 엉뚱한 카드를 짚지 않는다. 사이드바에는 그
    // 성질이 없어 카드에 정체를 따로 달아야 했다(§2m.75).
    const filtered: []const maru.session.agent_session_archive_view.Item = if (archive.query.len == 0) ordered else blk_q: {
        const buf = try scratch.alloc(maru.session.agent_session_archive_view.Item, ordered.len);
        var kept: usize = 0;
        for (ordered) |vi| {
            if (vi.record_index >= archive.cards.len) continue;
            const c = archive.cards[vi.record_index];
            // 제목·요약·폴더를 본다 — 사용자가 기억하는 것이 셋 중 하나다.
            if (asciiContainsIgnoreCase(c.title, archive.query) or
                asciiContainsIgnoreCase(c.summary, archive.query) or
                asciiContainsIgnoreCase(vi.cwd, archive.query))
            {
                buf[kept] = vi;
                kept += 1;
            }
        }
        break :blk_q buf[0..kept];
    };
    var projection = try maru.session.agent_session_archive_view.build(scratch, filtered, archive.collapsed.items);
    defer projection.deinit(scratch);
    for (projection.entries.items) |entry| switch (entry) {
        .group => |gi| {
            const g = projection.groups.items[gi];
            try out.append(persist, .{
                .group = .{
                    .identity = gi,
                    // **라벨은 투영이 매번 새로 만든다** — 이 arena 는 곧 사라지므로 복사한다.
                    .label = try persist.dupe(u8, g.label),
                    .count = @intCast(@min(g.count, std.math.maxInt(u16))),
                    .collapsed = g.collapsed,
                },
            });
        },
        .card => |ri| {
            if (ri >= archive.cards.len) continue;
            const c = archive.cards[ri];
            try out.append(persist, .{ .card = .{
                .identity = ri,
                .provider = c.provider,
                .title = c.title,
                .summary = c.summary,
                .metadata = .{ .messages = c.messages, .age = c.age, .model = c.model },
            } });
        },
    };
}

/// 인텐트 하나를 상태에 적용한다. 화면이 바뀌면 `true`.
///
/// **지금 지킬 수 있는 것만 지킨다.** 나머지(`scope`·`toggle_sort`·`refresh`·`resume_session` …)는
/// 모델이 Windows 앱에 아직 없다 — 조용히 무시하지 않고 **여기 목록으로 남겨** 무엇이 빠졌는지가
/// 코드에서 보이게 한다.
fn applyAgentIntent(
    scratch: std.mem.Allocator,
    persist: std.mem.Allocator,
    archive: *AgentArchive,
    state: *agent_surface.State,
    items: *std.ArrayList(maru.chrome.components.session_dock.types.Item),
    intent: maru.chrome.components.session_dock.ids.Intent,
) bool {
    switch (intent) {
        .select_card => |identity| {
            // **같은 카드를 다시 누르면 접힌다.** 펼침이 하나뿐이라 그것이 유일한 닫는 방법이다.
            state.expanded_identity = if (state.expanded_identity == identity) null else identity;
            return true;
        },
        .toggle_group => |gi| {
            // **번호를 키로 바꾼다.** 인텐트의 `u64` 는 그 순간의 그룹 번호이고, 접기 상태는
            // 키(cwd)로 산다 — 목록이 바뀌어도 같은 그룹을 가리키게 하는 것이 그 차이다.
            const key = groupKeyAt(scratch, archive, gi) orelse return false;
            if (archive.isCollapsed(key)) {
                for (archive.collapsed.items, 0..) |k, i| {
                    if (std.mem.eql(u8, k, key)) {
                        _ = archive.collapsed.orderedRemove(i);
                        break;
                    }
                }
            } else {
                archive.collapsed.append(persist, key) catch return false;
            }
            projectAgentItems(scratch, persist, archive, items) catch return false;
            state.invalidateTree();
            return true;
        },
        .toggle_sort => {
            // **방향만 뒤집는다.** 어느 방향으로 갈지는 인텐트가 아니라 **지금 상태**가 정한다
            // (그 인텐트의 doc: 두 곳이 방향을 알면 published tree 와 host 상태가 어긋난다).
            archive.sort = switch (archive.sort) {
                .newest_first => .oldest_first,
                .oldest_first => .newest_first,
            };
            projectAgentItems(scratch, persist, archive, items) catch return false;
            state.invalidateTree();
            return true;
        },
        else => return false,
    }
}

/// 그 순간의 그룹 번호 → 그룹 키. 투영을 다시 돌려 얻는다 — 번호의 의미가 거기 있기 때문이다.
fn groupKeyAt(scratch: std.mem.Allocator, archive: *const AgentArchive, gi: u64) ?[]const u8 {
    // **고정 버퍼를 안 쓴다.** 4 KiB 로 두었더니 이력이 커지는 순간 투영이 실패하고, 그러면 이
    // 함수가 `null` 을 내 **그룹 토글이 조용히 아무 일도 안 한다** — 사용자에겐 "가끔 안 눌린다"
    // 로 보인다. 호출자가 이미 버리는 arena 를 들고 있으므로 그것을 쓴다(상한이 사라진다).
    var projection = maru.session.agent_session_archive_view.build(scratch, archive.view_items, archive.collapsed.items) catch return null;
    defer projection.deinit(scratch);
    if (gi >= projection.groups.items.len) return null;
    // **호출자 arena 가 아니라 archive 가 이미 든 키를 돌려준다** — 투영은 곧 사라진다.
    const key = projection.groups.items[gi].key;
    for (archive.view_items) |vi| {
        const k = if (vi.cwd_canonical and vi.cwd.len > 0) vi.cwd else "";
        if (std.mem.eql(u8, k, key)) return k;
    }
    return null;
}

/// 이력 훑기를 **제출만** 한다. 결과는 `drainAgentItems` 가 프레임 루프에서 받는다.
///
/// **백엔드가 이 함수보다 오래 산다** — 예전에는 여기서 만들고 여기서 버리며 그 사이 3000 회까지
/// `sleep(1ms)` 로 기다렸다. 이력이 큰 기계에서는 그 시간 동안 **창이 아예 안 떴다.** 트리 펼치기와
/// 같은 모양으로 갈랐다(§2m.68).
/// 훑기 메모리가 **돌아오는지** 재려고 감싸는 allocator. 최고점과 지금 살아 있는 양을 센다.
///
/// arena 로는 이것을 못 잰다 — arena 는 원래 안 돌려주므로 `queryCapacity` 가 최고점에서 안 내려온다.
/// 그리고 그 최고점이 이 기계에서 **40 MB** 다: 훑는 동안만 필요한 것을 앱 수명으로 들고 있으면
/// 창 하나가 그만큼을 계속 물고 있게 된다.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn note(self: *CountingAllocator, delta_add: usize, delta_sub: usize) void {
        self.live = self.live + delta_add - delta_sub;
        if (self.live > self.peak) self.peak = self.live;
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.note(len, 0);
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(buf, a, new_len, ra)) return false;
        self.note(new_len, buf.len);
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(buf, a, new_len, ra) orelse return null;
        self.note(new_len, buf.len);
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
        self.note(0, buf.len);
    }
};

fn submitAgentScan(
    scan: std.mem.Allocator,
    backend: *agent_archive_backend.Backend,
    home: []const u8,
) []const u8 {
    const home_owned = scan.dupe(u8, home) catch return "scan_failed";
    if (!backend.submit(home_owned, false)) {
        scan.free(home_owned);
        return "submit_refused";
    }
    return "";
}

/// 와 있는 이력 결과를 받아 카드로 만든다. 아직 안 왔으면 `null` — **그 프레임은 그냥 지나간다.**
///
/// 돌려주는 문자열은 `agent_list_reason` 그대로다(`""` 이면 성공).
fn drainAgentItems(
    scan: std.mem.Allocator,
    persist: std.mem.Allocator,
    io: std.Io,
    backend: *agent_archive_backend.Backend,
    archive: *AgentArchive,
    out: *std.ArrayList(maru.chrome.components.session_dock.types.Item),
    /// **훑기가 끝났는가.** 중간 결과(`partial_progress`)는 아직 도는 중이라 false 다 — 호출자는
    /// 이 값으로 "분석 중" 표시를 내린다. 결과가 아예 없으면 건드리지 않는다(지금 상태 유지).
    finished_out: *bool,
    /// **일부만 훑었는가**(`outcome` 과 직교한다 — 백엔드 doc). 헤더가 "일부" 문구로 바꾼다.
    partial_out: *bool,
) ?[]const u8 {
    var res = backend.takeResult() orelse return null;
    defer res.deinit(scan);
    if (res.outcome == .completed or res.outcome == .cancelled) finished_out.* = true;
    partial_out.* = res.partial;
    switch (res.outcome) {
        // **자격이 있는 것만 목록을 갈아 끼운다.** `cancelled` 는 보이는 것을 대체할 자격이 없고
        // `retain_previous` 는 그 이름 그대로 이전을 지키라는 뜻이다(백엔드 doc). 갈아 끼우면
        // 취소된 세대의 부분 목록이 완성본 자리에 앉는다.
        .cancelled, .retain_previous => return null,
        .completed, .partial_progress => {},
    }
    return drainAgentItemsInner(scan, persist, io, &res, archive, out) catch "scan_failed";
}

fn drainAgentItemsInner(
    scan: std.mem.Allocator,
    persist: std.mem.Allocator,
    io: std.Io,
    res_in: *agent_archive_backend.Result,
    archive: *AgentArchive,
    out: *std.ArrayList(maru.chrome.components.session_dock.types.Item),
) ![]const u8 {
    const res = res_in.*;
    // **이유가 정확해야 한다.** 이력이 없는 것과 훑기가 깨진 것은 다른 사실인데, 둘 다 "카드 0" 으로
    // 끝난다 — 하나로 접으면 큰 이력을 가진 기계에서 "이력이 없다" 고 보고하게 된다.
    if (res.records.items.len == 0) return "no_history";

    // ── 레코드 → **오래 사는 재료** ──────────────────────────────────────────────────────────
    //
    // **문자열을 복사한다.** 전부 `res` 안의 메모리를 가리키는 슬라이스인데 이 함수를 나가며 그것을
    // `deinit` 한다 — arena 라 메모리가 살아 있어도 안전 빌드의 `Allocator.free` 가 해제한 자리를
    // `undefined`(0xAA)로 덮으므로 내용이 통째로 사라진다(§2m.57 실측).
    const now_ns: i128 = std.Io.Clock.real.now(io).nanoseconds;
    const vi = try persist.alloc(maru.session.agent_session_archive_view.Item, res.records.items.len);
    const cards = try persist.alloc(AgentCard, res.records.items.len);
    for (res.records.items, 0..) |rec, idx| {
        const p = rec.parsed;
        vi[idx] = .{
            .record_index = idx,
            .cwd = try persist.dupe(u8, p.cwd),
            .cwd_canonical = p.cwd_canonical,
        };
        // **메타는 세그먼트다**(한 문장이 아니다) — 컴포넌트가 구분자와 색을 소유해 위계를 준다.
        const messages = try std.fmt.allocPrint(persist, "{d}", .{p.message_count});
        var age_buf: [24]u8 = undefined;
        const age_src = maru.chrome.components.sidebar.formatRelativeAge(
            @intCast(@max(0, @divTrunc(now_ns - @as(i128, agent_archive_backend.lastActivityNs(rec)), 1_000_000))),
            &age_buf,
        );
        cards[idx] = .{
            .provider = switch (p.provider) {
                .claude => .claude,
                .codex => .codex,
            },
            .title = try persist.dupe(u8, p.title),
            .summary = try persist.dupe(u8, p.summary),
            .messages = messages,
            .age = try persist.dupe(u8, age_src),
            .model = try persist.dupe(u8, p.model),
        };
    }
    archive.view_items = vi;
    archive.cards = cards;
    // **첫 화면도 같은 함수가 만든다** — 접기 뒤와 다른 코드로 만들면 그 둘이 갈린다.
    var proj_arena = std.heap.ArenaAllocator.init(scan);
    defer proj_arena.deinit();
    try projectAgentItems(proj_arena.allocator(), persist, archive, out);
    return "";
}
/// 상태바 항목 하나 — **아이콘(선택) + 글자**. 정체는 중립 `ItemId` 가 갖는다(슬롯 인덱스를 id 로
/// 쓰면 항목 하나가 사라질 때 남은 것의 id 가 밀려 눌린 것과 실행된 것이 갈린다 — 그 enum 의 doc).
const StatusBarItem = struct {
    id: maru.chrome.components.status_bar.ItemId,
    /// 0 이면 아이콘 없는 항목이다(계약 §4 의 커서 위치·읽기 전용 같은 것들).
    icon: u21 = 0,
    text: []const u8,
};

/// 항목이 먹는 **셀 칸 수**. 아이콘과 글자 사이에 한 칸을 둔다.
///
/// **왜 셀로 재나 — 계약은 px 라고 했다.** 그 계약이 막으려는 것은 *폰트 폭을 추측하는 것*이다
/// (그 컴포넌트 헤더: "글꼴·CJK 폭을 여기서 추측하지 않는다"). Windows 의 크롬 글자는 지금 전부
/// **터미널 폰트를 셀 격자에 얹어** 그린다(`cell_text` + 터미널 프레임 빌더) — 그 격자에서 한 글자의
/// 폭은 `width.cellWidth` 가 **정확히** 정하지 추측이 아니다. 한글이 두 칸인 것도 그 함수가 안다.
///
/// **이 근거는 경로에 묶여 있다.** 상태바 글자를 measured 크롬 텍스트(§2m.27)로 옮기는 날, 폭의
/// 출처도 그쪽으로 함께 옮겨야 한다 — 그때 이 함수를 그대로 두면 비례 폰트 폭을 셀로 어림하게 된다.
fn statusBarItemCols(item: StatusBarItem) u32 {
    var cols: u32 = 0;
    if (item.icon != 0) cols += @as(u32, maru.width.cellWidth(item.icon)) + 1;
    // **그리는 쪽과 같은 플래너로 잰다**(`cell_text.titleCols`). 코드포인트를 손으로 세면 결합
    // 문자·이모지 ZWJ 에서 어긋나고, 그 어긋남은 폭을 재는 쪽에서만 나서 화면에서는 글자가 잘린
    // 것처럼 보인다 — `docs/grapheme-clustering.md` §3.1b 가 그 직접 디코드를 금지하고 경계 게이트가
    // 실제로 잡았다(실측 2026-08-26).
    cols += cell_text.titleCols(item.text, false);
    return cols;
}

/// 창 바닥 상태표시줄(W8.9). 배경 띠 + 상단 경계선 + 놓인 항목들.
///
/// **자리는 중립이 정한다**(`chrome.components.status_bar.compute`) — 좌/우 어느 쪽부터 채우는지,
/// 부딪히면 무엇을 먼저 버리는지가 전부 거기 있다. 여기서 산수를 하면 macOS 와 다른 순서로 버린다.
///
/// **항목마다 프레임이 하나다.** 계약이 그렇게 정했다(§3: 항목은 각자 자기 frame 을 갖고 절대 px
/// origin 에 놓인다). 한 프레임에 몰아 담고 열로 자리를 잡으면 px 로 계산된 자리가 **셀 격자로
/// 스냅되어** 계산과 화면이 갈린다(간격 12px 는 셀 폭 8 의 배수가 아니다).
fn appendStatusBarCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    bar: maru.session.split_tree.Rect,
    cell_w: u32,
    cell_h: u32,
    tk: *const maru.chrome.Tokens,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    items: []const StatusBarItem,
    frames: []?maru.renderer.RenderFrame,
    dropped_out: *usize,
    placed_out: *usize,
    outside_out: *usize,
    mismatch_out: *usize,
) !void {
    mismatch_out.* = 0;
    dropped_out.* = 0;
    placed_out.* = 0;
    outside_out.* = 0;
    for (frames) |*f| if (f.*) |*old| {
        old.deinit(allocator);
        f.* = null;
    };
    if (bar.w == 0 or bar.h == 0) return;

    // 배경 띠. **항상 선다** — 도크·사이드바 상태와 무관하다(계약 §2).
    try out.append(allocator, d3d11_cells.solidCell(
        @floatFromInt(bar.x),
        @floatFromInt(bar.y),
        @floatFromInt(bar.w),
        @floatFromInt(bar.h),
        cellColor(tk, .surface_bg),
        .{ 0, 0, 0, 0 },
    ));
    // **경계선은 띠 안쪽 맨 위**에 긋는다 — 밖에 그으면 작업영역을 한 줄 더 먹는다(그 상수의 doc).
    const border_px = @max(1, maru.session.layout_math.ptToPx(maru.status_bar_metrics.border_pt, 1000));
    try out.append(allocator, d3d11_cells.solidCell(
        @floatFromInt(bar.x),
        @floatFromInt(bar.y),
        @floatFromInt(bar.w),
        @floatFromInt(@min(border_px, bar.h)),
        cellColor(tk, .divider),
        .{ 0, 0, 0, 0 },
    ));

    if (items.len == 0 or cell_w == 0 or cell_h == 0) return;
    var widths: [max_status_bar_items]u32 = undefined;
    const n = @min(items.len, widths.len);
    for (items[0..n], 0..) |item, i| widths[i] = statusBarItemCols(item) *| cell_w;

    var left_slots: [max_status_bar_items]maru.chrome.components.status_bar.Slot = undefined;
    var right_slots: [1]maru.chrome.components.status_bar.Slot = undefined;
    const placed = maru.chrome.components.status_bar.compute(
        maru.status_bar_metrics.metricsFor(bar.x, bar.y, bar.w, bar.h, 1000),
        widths[0..n],
        &.{},
        &left_slots,
        &right_slots,
    );
    dropped_out.* = placed.dropped;

    // **글자는 띠 안에서 세로 중앙**이다. 바 높이가 셀보다 크게 유도되므로(그 잎의 `heightPx`)
    // 이 뺄셈이 0 으로 포화되지 않는다 — 포화되면 글자가 창 밖으로 넘친다.
    const text_y = bar.y + (bar.h -| cell_h) / 2;
    const fg_rgb = tk.get(.surface_fg);
    const fg: maru.terminal.Color = .{ .rgb = .{ .r = fg_rgb.r, .g = fg_rgb.g, .b = fg_rgb.b } };
    var natives: [max_status_bar_items]?[]maru.renderer.metal_frame.NativeMetalCell = @splat(null);
    var origins: [max_status_bar_items]u32 = @splat(0);

    for (placed.left, 0..) |slot, si| {
        if (si >= frames.len or slot.index >= n) continue;
        const item = items[slot.index];
        var cells: std.ArrayList(maru.renderer.DrawCell) = .empty;
        defer cells.deinit(allocator);
        // **grapheme 풀**. cluster 의 base 뒤 코드포인트(결합 악센트·NFD 한글 V/T·VS16)가 여기 실린다 —
        // 없으면 그 글자들이 조용히 사라진다(§3.1a CG1).
        var pool: std.ArrayList(u32) = .empty;
        defer pool.deinit(allocator);
        const style: maru.terminal.Style = .{ .foreground = fg };
        var col: u16 = 0;
        if (item.icon != 0) {
            try cells.append(allocator, .{ .row = 0, .col = col, .codepoint = item.icon, .style = style, .width = maru.width.cellWidth(item.icon) });
            col += @as(u16, maru.width.cellWidth(item.icon)) + 1;
        }
        // **자르지 않는다** — 상한을 항목 폭 그대로 준다. 자를지는 배치가 이미 정했다(자리를 못
        // 얻은 항목은 통째로 빠진다, 계약 §3).
        col = cell_text.appendEllipsizedTitle(allocator, &cells, &pool, item.text, 0, col, std.math.maxInt(u16), style, false, .head) catch col;
        // **잰 폭과 그린 폭이 같아야 한다.** 배치는 `statusBarItemCols` 가 준 폭으로 자리를
        // 잡았고 화면에는 여기 `col` 만큼 그려진다 — 둘이 갈리면 항목이 겹치거나 사이가 벌어지는데
        // `status_outside` 는 **바 밖으로 나갈 때만** 움직여 그것을 못 본다. 두 값은 서로 다른
        // 함수가 낸다(`titleCols` 는 0 부터, 여기는 아이콘 뒤부터 계획한다).
        if (col != statusBarItemCols(item)) mismatch_out.* += 1;
        if (cells.items.len == 0) continue;
        const list = maru.renderer.DrawList{
            .size = .{ .cols = col, .rows = 1 },
            .cursor = .{ .row = 0, .col = 0 },
            .dirty = null,
            .cells = try cells.toOwnedSlice(allocator),
            .overlays = try allocator.alloc(maru.renderer.DrawOverlay, 0),
            .grapheme_pool = try pool.toOwnedSlice(allocator),
        };
        var glyph_runs = maru.renderer.glyph_layout.buildGlyphRunList(allocator, list, renderer_state.text_config, builder.shaper) catch {
            var l = list;
            l.deinit(allocator);
            continue;
        };
        // **여기서 놓고 간다.** 프레임은 이것을 빌려 가지 않는다(사이드바 쪽이 이미 그렇게 쓴다) —
        // 안 놓으면 상태바를 다시 그릴 때마다 런 목록이 하나씩 샌다.
        defer glyph_runs.deinit(allocator);
        const frame = renderer_state.buildFrameFromGlyphRunListWithRasterizer(allocator, list, glyph_runs, builder.rasterizer) catch {
            var l = list;
            l.deinit(allocator);
            continue;
        };
        frames[si] = frame;
        // **짓는 자리에서 곧바로 올린다**(§2m.32) — 업로드 목록은 프레임과 함께 죽는다.
        try draw_host.syncAtlasTexture(pipeline, renderer_state, atlas_w, atlas_h);
        uploaded.* += draw_host.uploadFrameRegions(pipeline, frame);

        const colors = maru.renderer.metal_frame.CellColors{
            .default_fg = .{ .r = fg_rgb.r, .g = fg_rgb.g, .b = fg_rgb.b },
            .default_bg = .{ .r = 0, .g = 0, .b = 0 },
        };
        natives[si] = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, colors);
        origins[si] = slot.x;
        placed_out.* += 1;
    }

    // **UV 는 마지막 업로드 뒤에 잡는다.** 항목마다 아틀라스를 올리는데 뒤 항목이 아틀라스를 **키우면**
    // 앞 항목의 UV 가 옛 크기로 계산돼 있어 화면에서 사라진다 — 실측 2026-08-26: 브랜치 이름
    // `feat/w8-status-bar` 가 `fea` 세 글자만 남았다(이미 구워져 있던 글리프만 살아남았다).
    // 사이드바가 프레임 **하나**라 못 겪던 실패다.
    // **먼저 전부 해제 예약한다.** 아래에서 한 번이라도 실패해 함수를 나가면 남은 항목의 native 가
    // 새는데, 반복문 안의 `defer` 는 그 자리 것만 챙긴다.
    defer for (natives) |maybe| if (maybe) |native| allocator.free(native);
    for (natives, origins) |maybe_native, ox| {
        const native = maybe_native orelse continue;
        try out.ensureUnusedCapacity(allocator, native.len);
        for (native) |src| {
            var c = src;
            // **계산된 px 자리에 그대로 놓는다** — 열은 항목 **안에서**의 자리이고, 항목의 자리는
            // `origin_x` 다. 열로 자리를 잡으면 격자에 스냅돼 계산과 갈린다.
            c.origin_x = ox;
            c.origin_y = text_y;
            c.row = 0;
            const cell = win32_terminal.cellFromNative(c, cell_w, cell_h, atlas_w.*, atlas_h.*);
            if (cell.rect[0] < @as(f32, @floatFromInt(bar.x)) or
                cell.rect[0] + cell.rect[2] > @as(f32, @floatFromInt(bar.x + bar.w)) or
                cell.rect[1] < @as(f32, @floatFromInt(bar.y)) or
                cell.rect[1] + cell.rect[3] > @as(f32, @floatFromInt(bar.y + bar.h))) outside_out.* += 1;
            out.appendAssumeCapacity(cell);
        }
    }
}

/// 지금 낼 수 있는 상태바 항목들. **좌측 둘뿐이다** — 우측(에이전트 개수·알림·커서 위치)은 그
/// 모델이 Windows 앱에 아직 없다(계약 §4 의 표에서 그 줄들이 "0이면 항목 없음" 인 것과 같은 결과다).
///
/// **빈 항목은 안 넣는다.** repo 밖이면 브랜치 줄이 없고 cwd 가 없으면 경로 줄이 없다 — 그것이
/// 계약이고, 빈 문자열을 넣으면 폭 0 짜리 항목이 `dropped` 로 세어져 "폭이 모자랐다" 로 읽힌다.
fn buildStatusBarItems(
    out: []StatusBarItem,
    scm_status: []const u8,
    cwd: ?[]const u8,
    home: ?[]const u8,
    cwd_buf: []u8,
) []const StatusBarItem {
    var n: usize = 0;
    const icons = maru.icons;
    if (maru.session.git_status.parseHead(scm_status).branch) |b| {
        if (b.len != 0 and n < out.len) {
            out[n] = .{ .id = .git_branch, .icon = icons.codepoint(.git_branch), .text = b };
            n += 1;
        }
    }
    if (cwd) |c| {
        if (c.len != 0 and n < out.len) {
            out[n] = .{ .id = .cwd, .icon = icons.codepoint(.folder), .text = shortenHome(c, home, cwd_buf) };
            n += 1;
        }
    }
    return out[0..n];
}

/// `$HOME` 을 `~` 로 줄인다(계약 §4 의 `sidebarCwdPath` 규칙). 못 줄이면 원본을 그대로 돌려준다 —
/// **버퍼가 모자라도 자르지 않는다**: 자르는 것은 텍스트 단계의 일이고, 여기서 자르면 폭 계산이
/// 두 곳으로 갈린다(그 컴포넌트 §3).
fn shortenHome(path: []const u8, home: ?[]const u8, buf: []u8) []const u8 {
    const h = home orelse return path;
    if (h.len == 0 or path.len < h.len) return path;
    if (!std.mem.eql(u8, path[0..h.len], h)) return path;
    const rest = path[h.len..];
    // **구분자는 타깃이 아니라 데이터가 정한다.** `std.fs.path.sep` 을 쓰면 같은 Windows 경로가
    // 빌드 타깃마다 다르게 처리된다 — Linux 빌드에서 `sep` 은 `/` 라 역슬래시로 이어진 경로가 안 줄어든다.
    // 이 함수가 보는 것은 **Windows 가 준 경로**이고 거기엔 둘 다 나온다(실측 2026-08-26: CI 가
    // 이 테스트를 Linux 에서 돌려 잡았다 — 로컬은 Windows 라 초록이었다).
    if (rest.len != 0 and rest[0] != '\\' and rest[0] != '/') return path;
    if (1 + rest.len > buf.len) return path;
    buf[0] = '~';
    @memcpy(buf[1..][0..rest.len], rest);
    return buf[0 .. 1 + rest.len];
}

/// 상태바를 다시 짓는다. **기하가 바뀌는 자리마다 부른다** — 자리를 안 갱신하면 창을 키운 뒤
/// 옛 사각형에 남아 화면에서 사라진다(실측 2026-08-26).
fn rebuildStatusBar(
    a: std.mem.Allocator,
    cells_out: *std.ArrayList(d3d11_cells.Cell),
    bar: maru.session.split_tree.Rect,
    cw: u32,
    ch: u32,
    tk: *const maru.chrome.Tokens,
    rs: *maru.renderer.RendererState,
    fb: win32_terminal.FrameBuilder,
    pl: *d3d11_cells.CellPipeline,
    aw: *u32,
    ah: *u32,
    up: *usize,
    items: []const StatusBarItem,
    frames: []?maru.renderer.RenderFrame,
    dropped: *usize,
    placed: *usize,
    outside: *usize,
    mismatch: *usize,
    rebuilds: *usize,
) void {
    cells_out.clearRetainingCapacity();
    appendStatusBarCells(a, cells_out, bar, cw, ch, tk, rs, fb, pl, aw, ah, up, items, frames, dropped, placed, outside, mismatch) catch {};
    rebuilds.* += 1;
}

/// 세로 스크롤바 한 벌(트랙 + thumb)을 셀로 낸다.
///
/// **기하는 중립이 준다**(`chrome.ui.scroll_area.scrollbarGeometry`) — 트랙 자리, thumb 길이·위치,
/// 잡는 자리가 전부 거기서 나온다. 여기서 산수를 하면 **그린 자리와 잡히는 자리가 갈린다**(그
/// 모듈의 doc 이 "그리는 폭과 잡는 폭은 다르다" 로 그 실패를 적어 뒀다).
///
/// **색은 SCM 도크와 같은 역할을 쓴다** — 트랙 `inset_bg`, thumb `muted_fg`(`scm_dock/build.zig`).
/// 여기서 다른 역할을 고르면 같은 앱 안에서 스크롤바 둘이 다른 색이 된다.
/// 포인터가 이 막대의 **잡는 자리** 안인가. 그리는 폭이 아니라 거터 전체다 — 막대가 8px 이라
/// 보이는 띠를 정확히 찍어야만 잡히면 조준이 1mm 짜리 과제가 된다(중립 doc 의 그 이유).
fn barHit(b: maru.chrome.ui.scroll_area.ScrollbarGeometry, x_px: i32, y_px: i32) bool {
    const x: f32 = @floatFromInt(x_px);
    const y: f32 = @floatFromInt(y_px);
    return x >= b.hit_x and x < b.hit_x + b.hit_w and y >= b.track_y and y < b.track_y + b.track_h;
}

fn appendScrollbarCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    bar: maru.chrome.ui.scroll_area.ScrollbarGeometry,
    tk: *const maru.chrome.Tokens,
) !void {
    try out.append(allocator, d3d11_cells.solidCell(
        bar.track_x,
        bar.track_y,
        bar.track_w,
        bar.track_h,
        cellColor(tk, .inset_bg),
        .{ 0, 0, 0, 0 },
    ));
    try out.append(allocator, d3d11_cells.solidCell(
        bar.track_x,
        bar.thumb_y,
        bar.track_w,
        bar.thumb_h,
        cellColor(tk, .muted_fg),
        .{ 0, 0, 0, 0 },
    ));
}

/// 이 창의 스크롤바 치수. **도크와 사이드바가 같은 값을 쓴다** — 한 화면에 굵기가 둘이면 사용자가
/// 다른 컨트롤로 읽는다. 값의 단일 출처는 `session_dock` 의 `DockMetrics` 다(macOS 도 그것을 쓴다).
fn scrollbarMetrics() maru.chrome.ui.scroll_area.ScrollbarMetrics {
    return maru.chrome.components.session_dock.types.DockMetrics.resolve(1000).scrollbarMetrics();
}

/// 스크롤 컨테이너가 **상시 비워 두는** 오른쪽 폭.
///
/// **넘칠 때만 비우면 안 된다.** 그러면 목록이 길어지는 순간 글자가 한 칸 좁아지며 **전체가
/// 다시 흐른다** — 항목을 하나 더할 때마다 화면이 출렁인다. 중립도 같은 말을 한다: 거터는
/// *"컨테이너가 자기 폭에서 **상시** 예약하는 자리"* 다.
fn scrollGutterPx() u32 {
    return scrollbarMetrics().gutterPx();
}

/// 도크 트리의 세로 스크롤바 기하. 없으면 `null`(넘치지 않거나 자리가 안 난다).
///
/// **거터를 뺀 폭이 글자의 폭이고, 거터 자체가 막대의 자리다.** 둘을 여기 한 곳에서 내야
/// 그린 자리와 잡는 자리가 안 갈린다.
fn dockScrollbarGeometry(
    geom: maru.session.dock_layout.Geometry,
    rows_len: usize,
    cell_h: u32,
    offset_px: u32,
) ?maru.chrome.ui.scroll_area.ScrollbarGeometry {
    const m = scrollbarMetrics();
    const gutter = m.gutterPx();
    const area = geom.tree_content;
    if (area.w <= gutter) return null;
    return maru.chrome.ui.scroll_area.scrollbarGeometry(.{
        .x = @floatFromInt(area.x),
        .y = @floatFromInt(area.y),
        .w = @floatFromInt(area.w - gutter),
        .h = @floatFromInt(area.h),
        .gutter_w = @floatFromInt(gutter),
    }, @intCast(rows_len *| cell_h), offset_px, m);
}

/// 사이드바 카드 목록의 세로 스크롤바 기하. 헤더는 스크롤 밖이라 뷰포트에서 뺀다.
fn sidebarScrollbarGeometry(
    geom: maru.session.dock_layout.Geometry,
    header_h: u32,
    content_h: u32,
    offset_px: u32,
) ?maru.chrome.ui.scroll_area.ScrollbarGeometry {
    const m = scrollbarMetrics();
    const gutter = m.gutterPx();
    if (geom.sidebar.w <= gutter or geom.sidebar.h <= header_h) return null;
    return maru.chrome.ui.scroll_area.scrollbarGeometry(.{
        .x = 0,
        .y = @floatFromInt(geom.sidebar.y + header_h),
        .w = @floatFromInt(geom.sidebar.w - gutter),
        .h = @floatFromInt(geom.sidebar.h - header_h),
        .gutter_w = @floatFromInt(gutter),
    }, content_h, offset_px, m);
}

/// 카드 목록 → 사이드바 행 목록. **그리는 쪽과 누르는 쪽이 같은 함수를 쓴다** — 카드 높이가
/// 줄 수에서 나오므로 두 곳에서 따로 만들면 `slotAt` 의 누적이 밴드와 어긋난다.
/// 그 활성 슬롯이 **통째로** 사이드바 뷰포트 안에 있는가 — 판정 전용이다.
///
/// 자리는 중립이 소유한다(`rowTop`·`rowHeight`) — 여기서 누적을 다시 적으면 그린 자리와 갈린다.
fn sidebarSlotFullyVisible(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(maru.chrome.components.sidebar.Row),
    cards: []const SidebarCard,
    view: ActiveView,
    header_h: u32,
    cell_h: u32,
    sidebar_h: u32,
    scroll_px: u32,
) bool {
    const slot = sidebarActiveSlot(cards, view);
    const rows = sidebarRowsFor(allocator, scratch, cards, slot);
    if (slot >= rows.len) return false;
    const m = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
    const top = maru.chrome.components.sidebar.rowTop(rows, slot, header_h, m, scroll_px);
    const bottom = top + @as(i64, maru.chrome.components.sidebar.rowHeight(rows[slot], m));
    return top >= @as(i64, header_h) and bottom <= @as(i64, sidebar_h);
}

/// 카드 목록을 사이드바 `Row` 로 옮긴다 — **개수 상한이 없다.**
///
/// 예전에는 호출부마다 `[16]` 짜리 배열을 잡아 `@min(cards.len, buf.len)` 으로 **말없이 잘랐다.**
/// 그리기는 `cards` 를 끝까지 훑으므로(그 함수의 `while (first < cards.len)`), 카드가 열여섯을
/// 넘으면 **그려지는 목록과 기하·히트테스트·스크롤 상한이 갈렸다** — 열일곱 번째 카드는 보이는데
/// 굴려 갈 수가 없었다. 세션 상한이 `max_win_sessions`(16)이고 **연 파일 수에는 상한이 없어서**
/// 실제로 닿는 자리다.
///
/// **스크래치는 호출부가 준다**(한 벌을 돌려 쓴다). 돌려준 슬라이스는 **다음 호출까지만** 유효하다 —
/// 두 목록을 동시에 들고 있으면 안 된다. 할당이 실패하면 담긴 만큼만 돌려준다(옛 잘림과 같은 모습).
fn sidebarRowsFor(
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(maru.chrome.components.sidebar.Row),
    cards: []const SidebarCard,
    active: usize,
) []const maru.chrome.components.sidebar.Row {
    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(allocator, cards.len) catch {};
    for (cards, 0..) |c, i| {
        if (scratch.items.len == scratch.capacity) break;
        scratch.appendAssumeCapacity(.{ .card = .{ .tab = @intCast(i), .label = c.name, .active = i == active, .lines = @intCast(c.lines) } });
    }
    return scratch.items;
}

/// 창이 든 세션 하나 — **표면 · PTY · pump 한 벌**.
///
/// **왜 힙에 고정하나**: `AppWindow` 의 doc 이 그 이유를 소유한다 — `SurfaceRuntime` 이 `*Surface` 를
/// 라우팅에 보관하고 리더 스레드가 `&reader` 를 잡으므로, 목록이 realloc 될 때 본체가 움직이면 그
/// 포인터들이 dangling 된다. 그래서 목록은 `*WinSession` 만 든다.
/// 사이드바가 전환하는 것 — 터미널이거나 **연 파일**이다.
///
/// 문서가 정한 목적지는 "활성 워크스페이스 pane 의 새 탭"(file-panel.md §6)인데 Windows 에는 아직
/// pane 탭 스트립이 없다. 사용자 결정(2026-08-27)으로 **이미 있는 전환기**(사이드바 카드)를 쓴다 —
/// 새 모델을 세우지 않고 §2m.51 이 만든 배선을 그대로 탄다.
const ActiveView = union(enum) { terminal: usize, file: usize };

/// 연 파일 하나. **텍스트를 우리가 소유한다** — `lines` 의 슬라이스가 그 안을 가리킨다.
const OpenFile = struct {
    path: []u8,
    text: []u8,
    lines: std.ArrayList([]const u8),
    line_starts: []usize,
    /// 뷰포트 맨 위 줄. 파일마다 따로 산다 — 파일을 오갈 때 자리를 잃으면 안 된다.
    first_line: usize = 0,
    /// 가로 스크롤 위치(열). **계약은 "가로 스크롤이 기본이고 랩은 토글"** 이다
    /// (`native-editor-visual-mapping.md` §…: `editor.wrap` 기본 `false`).
    first_col: u16 = 0,
    /// 문서에서 **가장 긴 줄**의 표시 폭. 중립이 이 값으로 막대 길이를 정하고, 가로 막대를 세울지도
    /// 이것으로 판단한다(`showsHorizontalBar`). 여는 순간 한 번 센다 — 읽기 전용이라 안 변한다.
    max_cols: u32 = 0,
    /// **오른쪽 끝** — 직전 프레임에서 중립이 세운 가로 막대의 `max_offset_px` 를 열로 바꾼 값이다.
    /// 여기서 `max_cols - 보이는 열` 로 다시 세지 않는 이유: 본문은 gutter(줄 번호·접기·여백)만큼
    /// 좁아서 그 산수가 **거터 폭만큼 어긋난다** — 실측으로 끝까지 굴려도 마지막 41 열이 안 왔다.
    /// 막대가 없으면(넘치지 않으면) 0 이고, 그때는 굴릴 곳도 없다.
    hmax_col: u16 = 0,

    /// 사이드바 카드에 뜨는 이름. **경로 안을 가리킨다**(따로 복사하지 않는다).
    fn name(self: *const OpenFile) []const u8 {
        return std.fs.path.basename(self.path);
    }

    fn deinit(self: *OpenFile, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
        allocator.free(self.line_starts);
        allocator.free(self.text);
        allocator.free(self.path);
    }
};

/// 파일을 읽어 편집기가 쓸 재료로 만든다. **여는 규칙은 중립이 소유한다**
/// (`file_panel_bridge.openKindForPath`) — 확장자 표를 여기서 다시 적으면 macOS 와 갈린다.
///
/// 지금은 `.text` 만 연다. `.markdown`·`.html` 등의 본문은 계약상 WebView 이고 Windows 에서는
/// WebView2(W8.6)라 아직 없다 — **조용히 텍스트로 열지 않는다.** 그러면 마크다운이 렌더된 줄
/// 알았는데 소스가 뜨는 것을 사용자가 겪는다.
/// 왜 안 열렸는가. **뭉개면 안 된다** — "이 확장자는 아직 못 연다"(계약)와 "읽다가 실패했다"(결함)와
/// "너무 커서 못 읽는다"(상한)는 서로 다른 사실인데, 하나로 접으면 큰 파일을 못 여는 회귀가
/// "원래 안 여는 종류" 로 보인다. §2m.57 이 `scan_timeout`·`no_history` 로 같은 교훈을 남겼다.
const OpenOutcome = union(enum) {
    opened: OpenFile,
    /// 이진 파일 등 — 외부 앱의 것이다(중립 `openKindForPath` 가 `null` 을 낸다).
    unsupported,
    /// `.md`·`.html`·이미지 … 본문이 WebView 라 Windows 는 W8.6 이 선행이다.
    needs_web_panel,
    /// 읽기 실패 — 권한·삭제됨·**4 MiB 상한 초과**.
    read_failed,
    out_of_memory,

    fn name(self: std.meta.Tag(OpenOutcome)) []const u8 {
        return switch (self) {
            .opened => "opened",
            .unsupported => "unsupported",
            .needs_web_panel => "needs_web_panel",
            .read_failed => "read_failed",
            .out_of_memory => "out_of_memory",
        };
    }
};

fn openFileFor(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) OpenOutcome {
    const kind = maru.session.file_panel_bridge.openKindForPath(path) orelse return .unsupported;
    if (kind != .text) return .needs_web_panel;

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 << 20)) catch return .read_failed;
    errdefer allocator.free(text);
    const owned_path = allocator.dupe(u8, path) catch return .out_of_memory;
    errdefer allocator.free(owned_path);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, 0x0A);
    // CRLF 를 여기서 벗긴다 — 편집기 뷰는 **표시 텍스트**를 받는다(스모크가 쓰는 그 규칙).
    while (it.next()) |raw| lines.append(allocator, std.mem.trimEnd(u8, raw, "\r")) catch return .out_of_memory;

    const starts = allocator.alloc(usize, lines.items.len) catch return .out_of_memory;
    var off: usize = 0;
    var widest: u32 = 0;
    for (lines.items, starts) |l, *st| {
        st.* = off;
        off += l.len + 1;
        // **표시 폭이다**(바이트 수가 아니다) — 한글·CJK 는 두 칸이라 바이트로 세면 막대가 거짓말을
        // 한다. 폭 규약은 중립이 소유한다(`overlay_input.displayCols`).
        // **여기까지만 센다** — 상한도 중립이 소유한다(`frame.max_cols_count_limit`: 그 너머는
        // `max_first_col` 때문에 어차피 못 가므로 세는 것이 낭비다). 1 MB 짜리 한 줄 파일이 와도
        // 여는 데 드는 값이 이 상한에 묶인다.
        const limit = maru.chrome.components.editor_view.frame.max_cols_count_limit;
        widest = @max(widest, @min(limit, maru.chrome.components.overlay_input.displayCols(l)));
        if (widest >= limit) break;
    }
    return .{ .opened = .{ .path = owned_path, .text = text, .lines = lines, .line_starts = starts, .max_cols = widest } };
}

/// 합성 창에서 편집기 한 프레임. **스크래치를 여기서 잡고 곧바로 놓는다** — 스모크는 한 파일을
/// 오래 들고 있어 미리 잡아 두지만, 여기서는 파일이 오갈 때마다 줄 수가 바뀐다.
///
/// 배경 사각은 **pane 원점에 딱 맞는다**(스모크처럼 음수로 시작하지 않는다 — 그 함수 doc).
fn buildComposedEditor(
    allocator: std.mem.Allocator,
    host: EditorHost,
    file: *const OpenFile,
    rect: maru.session.split_tree.Rect,
    ops: []maru.chrome.draw.Op,
    tokens: *const maru.chrome.Tokens,
    cell_w: u32,
    cell_h: u32,
) !EditorBuilt {
    const n_lines = file.lines.items.len;
    const text_bytes = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(text_bytes);
    const runs = try allocator.alloc(maru.chrome.draw.Run, 4096);
    defer allocator.free(runs);
    const content_rows = try allocator.alloc(editor_view.content.Row, 512);
    defer allocator.free(content_rows);
    const visual_rows = try allocator.alloc(editor_view.visual_map.VisualRow, 512);
    defer allocator.free(visual_rows);
    const gutter_rows = try allocator.alloc(editor_view.gutter.Row, 512);
    defer allocator.free(gutter_rows);
    const row_counts = try allocator.alloc(u32, n_lines + 1);
    defer allocator.free(row_counts);
    const count_scratch = try allocator.alloc(u8, editor_view.content.count_scratch_bytes);
    defer allocator.free(count_scratch);

    // **u16 로 자른다.** 창이 아무리 커도 격자는 u16 이고, `@intCast` 로 넘기면 안전 빌드에서
    // **패닉**이다 — 휠 경로에는 이 가드를 뒀는데 여기만 빠져 있었다(적대적 검증 7회차).
    const grid = maru.terminal.Size{
        .cols = @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(1, rect.w / cell_w))),
        .rows = @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(1, rect.h / cell_h))),
    };
    const sel_cap = @as(usize, grid.rows) + 2;
    const sel_rows = try allocator.alloc([]const editor_view.frame.Mark, sel_cap);
    defer allocator.free(sel_rows);
    const sel_buf = try allocator.alloc(editor_view.frame.Mark, sel_cap);
    defer allocator.free(sel_buf);
    const sel_spans = try allocator.alloc(editor_view.selection_marks.Span, sel_cap);
    defer allocator.free(sel_spans);

    const inset = editor_view.frame.content_inset_px;
    // **안쪽 사각은 pane 안에서 사방 inset 만큼 줄어든다.** 좌표는 pane 로컬이다 — 창 절대 좌표로
    // 옮기는 일은 `origin_x`·`origin_y` 가 한다(그 함수가 그렇게 갈라 뒀다).
    const inner: maru.chrome.draw.Rect = .{
        .x = 0,
        .y = 0,
        .w = rect.w -| inset * 2,
        .h = rect.h -| inset * 2,
    };
    const view: maru.chrome.draw.Rect = .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h };
    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 },
        .default_bg = .{ .r = 0x1E, .g = 0x24, .b = 0x30 },
    };
    return buildEditorFrame(
        allocator,
        host,
        file.first_line,
        file.lines.items,
        editor_view.frame.Scratch{
            .ops = ops,
            .text_bytes = text_bytes,
            .runs = runs,
            .content_rows = content_rows,
            .visual_rows = visual_rows,
            .gutter_rows = gutter_rows,
            .row_counts = row_counts,
            .count_scratch = count_scratch,
        },
        ops,
        tokens,
        colors,
        view,
        inner,
        cell_w,
        cell_h,
        grid,
        // **배경을 내용보다 inset 만큼 넓게 잡지 않는다** — 제품은 pane 원점에서 시작해 pane 크기다.
        .{ .x = -@as(i32, @intCast(inset)), .y = -@as(i32, @intCast(inset)), .w = rect.w, .h = rect.h },
        rect.x,
        rect.y,
        file.first_col,
        // **0 이면 안 준 것과 같다** — 중립은 `null` 을 "아직 안 셌다" 로 읽어 막대를 안 세운다.
        if (file.max_cols == 0) null else file.max_cols,
        null,
        .{ .line_starts = file.line_starts, .rows = sel_rows, .buf = sel_buf, .spans = sel_spans },
    );
}

const WinSession = struct {
    surface: maru.session.surface.Surface,
    live: maru.app.LivePtySession,
    pump: maru.app.RuntimeEventPump,
    /// 사이드바 카드에 뜨는 이름. 세션이 소유한다(목록이 커져도 슬라이스가 살아 있어야 한다).
    name: [24]u8,
    name_len: usize,

    const SpawnOptions = struct {
        io: std.Io,
        command: []const u8,
        args: []const []const u8,
        size: maru.terminal.Size,
        cfg: maru.config.theme.Config,
        appearance: maru.config.appearance.ResolvedAppearance,
        cell_w: u32,
        cell_h: u32,
    };

    fn label(self: *const WinSession) []const u8 {
        return self.name[0..self.name_len];
    }

    fn destroy(self: *WinSession, allocator: std.mem.Allocator) void {
        // **PTY 를 먼저 내린다** — 리더 스레드가 표면 코어를 잡고 있다.
        self.live.deinit();
        self.surface.deinit();
        allocator.destroy(self);
    }
};

/// 세션 하나를 띄워 목록·탭에 붙인다.
///
/// **탭 슬라이스를 다시 건다**(`app_window.tabs = tab_ptrs.items`) — `ArrayList` 가 realloc 되면 옛
/// 슬라이스가 죽은 메모리를 가리킨다. 포인터가 가리키는 표면 본체는 힙에 고정이라 안전하다.
fn spawnWinSession(
    allocator: std.mem.Allocator,
    sessions: *std.ArrayList(*WinSession),
    tab_ptrs: *std.ArrayList(*maru.session.surface.Surface),
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    /// **단조 증가 세션 번호.** 목록 길이가 아니다 — 닫으면 길이가 줄어 번호가 되살아난다.
    next_session_id: *usize,
    opts: WinSession.SpawnOptions,
) !void {
    const s = try allocator.create(WinSession);
    errdefer allocator.destroy(s);

    // **PTY id 는 겹치면 안 된다** — 라우팅이 그 값으로 세션을 가른다.
    //
    // **길이에서 뽑으면 안 된다.** 닫기가 생기기 전에는 길이가 단조 증가라 우연히 맞았는데(W8.16),
    // 하나를 닫으면 그 번호가 되살아나 **살아 있는 세션과 겹친다.** 런타임이 그것을 잡아
    // `SurfaceAlreadyAttached` 로 거절하므로 오배선은 없지만, **닫은 뒤에는 ＋ 가 아무 일도 안 하게
    // 된다**(적대적 검증 2회차 실측). 그래서 **단조 증가 계수기**에서 뽑는다.
    next_session_id.* += 1;
    const seq = next_session_id.*;
    const pty_id: u32 = @intCast(10 + seq);
    s.surface = try maru.session.surface.Surface.init(allocator, @intCast(1 + seq), opts.size);
    errdefer s.surface.deinit();
    s.surface.command = opts.command;

    // **폴백도 버퍼에 쓴다.** 예전 판은 실패 시 리터럴을 `written` 에 담고 `buf` 는 손도 안 댔는데,
    // 그러면 초기화 안 된 스택을 복사해 길이만 7 인 **쓰레기 이름**이 된다. 지금 폭(24)과 상한(16)
    // 에서는 `bufPrint` 가 실패하지 않지만, 형식이나 상한을 바꾸는 날 조용히 밟는 자리다.
    s.name = std.mem.zeroes([24]u8);
    const written = std.fmt.bufPrint(&s.name, "session {d}", .{seq}) catch blk: {
        const fallback = "session";
        @memcpy(s.name[0..fallback.len], fallback);
        break :blk s.name[0..fallback.len];
    };
    s.name_len = written.len;
    s.surface.title = s.label();

    // **앱 수준 config 를 코어에 한 번에 건다** — 리더가 뜨기 전에. 값마다 명령을 따로 보내면 자식의
    // 첫 출력이 그 사이에 끼어 옛 설정으로 파싱되는 자리가 생긴다.
    applyCoreConfig(&s.surface.core, opts.cfg, opts.appearance, opts.cell_w, opts.cell_h);

    try s.live.init(opts.io, allocator, pty_id, .{ .command = opts.command, .args = opts.args, .size = opts.size }, 16);
    errdefer s.live.deinit();
    _ = try s.live.attachSurface(runtime, &s.surface, true);
    // **붙였으면 실패 경로에서 떼야 한다.** `deinit()` 이 부르는 `close()` 는 **라우팅을 안 끊는다**
    // (그건 `closeAndDetach`/`detachSurface` 의 일이다). 아래 `append` 가 실패하면 표면은 해제되는데
    // runtime 은 그 포인터를 계속 들고 있어 **dangling** 이 된다 — `attachSurface` 자신도 실패
    // 경로에서 같은 detach 를 한다(그 함수가 세운 규칙을 그대로 따른다).
    errdefer s.live.detachSurface(runtime);
    s.pump = s.live.pump(runtime);

    try sessions.append(allocator, s);
    errdefer _ = sessions.pop();
    try tab_ptrs.append(allocator, &s.surface);
    app_window.tabs = tab_ptrs.items;
}

/// id 로 세션 번호를 다시 푼다. **보류한 대상은 번호가 아니라 id 다** — 모달이 떠 있는 동안 목록이
/// 밀리면 같은 번호가 다른 세션을 가리킨다(적대적 검증 3회차 실측). 사라졌으면 `null`.
fn sessionIndexById(sessions: []const *WinSession, id: ?u64) ?usize {
    const want = id orelse return null;
    for (sessions, 0..) |s, i| {
        if (s.surface.id == want) return i;
    }
    return null;
}

/// 확인 모달이 자기 자리를 잡는 데 필요한 chrome props.
///
/// **그리는 쪽과 히트테스트가 같은 값을 받아야 한다** — 중립 `confirm.view` 와 `buttonAtPoint` 가
/// 둘 다 이것을 보고 상자를 놓는다(그 컴포넌트가 `modal_box` 프리미티브에 위임한다). 한쪽만
/// 다른 값을 주면 "보이는 버튼 ≠ 눌리는 버튼" 이 된다 — 사이드바에서 이미 그 함정을 봤다(§2m.74).
fn confirmProps(client_w: u32, client_h: u32, cell_w: u32, cell_h: u32, sidebar_w: u32) maru.chrome.props.ChromeProps {
    return .{ .metrics = .{
        .cell_width_px = cell_w,
        .cell_height_px = cell_h,
        .sidebar_width_px = sidebar_w,
        .backing_width_px = client_w,
        .backing_height_px = client_h,
    } };
}

/// 세션 하나를 닫아 목록·탭에서 뺀다. **왜 안 닫혔는지**를 돌려준다.
///
/// **계약은 이미 있다**(`macos-app-host-boundary.md`): 사이드바 ✕ 는 `requestClose` 게이트를 타고,
/// *"실행 중 명령이 있으면 확인 모달을 띄우고 닫기를 보류, 없으면 즉시"* 다. 판정 술어도 중립이
/// 소유한다(`TerminalCore.cursorIsAtPrompt` — OSC 133 의미 상태로 단위 테스트가 고정한다).
///
/// **Windows 에는 확인 모달이 없다.** 그래서 실행 중이면 **안 닫고 이유를 낸다** — 조용히 죽이면
/// 사용자가 돌려받을 수 없는 것을 잃는다. 모달이 생기는 날 이 자리에 이어 붙인다.
const CloseSessionResult = enum {
    closed,
    /// 실행 중인 명령이 있다 — 모달이 선행이다.
    busy_needs_confirm,
    /// 마지막 하나다. macOS 는 이때 **창이 닫히고 앱이 종료**된다 — Windows 에서 그 결정을 여기서
    /// 대신 내리지 않는다.
    last_session,
    out_of_range,
};

fn closeWinSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    sessions: *std.ArrayList(*WinSession),
    tab_ptrs: *std.ArrayList(*maru.session.surface.Surface),
    app_window: *maru.session.window.AppWindow,
    runtime: *maru.app.SurfaceRuntime,
    index: usize,
    /// 확인을 이미 받았나. **`true` 는 "사용자가 예를 눌렀다" 는 뜻이지 "검사를 건너뛴다" 가 아니다**
    /// — 마지막 하나 보호는 그대로다(그것은 앱 종료 결정이라 확인의 대상이 다르다).
    confirmed: bool,
) CloseSessionResult {
    if (index >= sessions.items.len) return .out_of_range;
    if (sessions.items.len <= 1) return .last_session;
    const s = sessions.items[index];
    // **락 아래에서 묻는다** — 리더 스레드가 같은 코어를 쓴다.
    const at_prompt = blk: {
        s.surface.lockCore(io);
        defer s.surface.unlockCore(io);
        break :blk s.surface.core.cursorIsAtPrompt();
    };
    if (!at_prompt and !confirmed) return .busy_needs_confirm;

    // **라우팅을 먼저 끊는다.** `destroy` 가 부르는 `deinit` 은 라우팅을 안 끊으므로(그 함수 주석),
    // 여기서 안 떼면 runtime 이 해제된 표면을 계속 든다.
    s.live.closeAndDetach(runtime);
    _ = sessions.orderedRemove(index);
    _ = tab_ptrs.orderedRemove(index);
    app_window.tabs = tab_ptrs.items;
    // **활성 탭을 removal 에 맞춰 당긴다.** 번호만 clamp 하면 앞쪽을 닫았을 때 **보고 있던 세션이
    // 조용히 바뀐다** — 뒤 색인이 하나씩 앞으로 당겨지기 때문이다. 화면은 멀쩡해 보이고 개수 판정도
    // 초록이라, 이름을 견주는 판정을 넣기 전까지 안 보였다(적대적 검증 1회차: `want=session 5
    // got=session 6`). 파일 목록에서 이미 같은 함정을 밟았다(W8.14).
    if (index < app_window.active_tab) {
        app_window.active_tab -= 1;
    } else if (app_window.active_tab >= sessions.items.len) {
        // 닫은 것이 활성이었고 그것이 마지막이면 앞으로 당긴다(그 외에는 같은 번호가 곧 승계자다).
        app_window.active_tab = sessions.items.len - 1;
    }
    s.destroy(allocator);
    return .closed;
}

/// 사이드바 카드 한 장이 싣는 것. 빈 문자열이면 그 줄을 안 그린다(`buildSidebarDrawList` 의 계약).
const SidebarCard = struct {
    name: []const u8,
    branch: []const u8 = "",
    folder: []const u8 = "",
    lines: u8 = 1,
    /// **이 카드가 무엇인가.** 슬롯 번호에서 산수로 되돌리면(`s >= sessions.len`) 목록이 **걸러지는**
    /// 순간 어긋난다 — 검색이 카드를 빼면 번호와 실물이 갈린다. 카드가 자기 정체를 든다.
    source: Source = .{ .session = 0 },

    const Source = union(enum) { session: usize, file: usize };
};

/// 소스 컨트롤 뷰가 그리는 데 필요한 것들.
const ScmDockInputs = struct {
    status: []const u8,
    state: *scm_surface.State,
    opts: scm_surface.Options,
    /// 마지막으로 지은 표면. **히트테스트가 이것을 본다** — 그리기와 누르기가 같은 tree 를 써야
    /// 누른 자리와 열리는 자리가 안 갈린다.
    built: *?scm_surface.Built,
};

/// 뷰 스위처 바 — **칸 세 개와 지금 뷰의 강조**. 아이콘은 아직 안 그린다(⒞3) — 칸이 눌리고 내용이
/// 바뀌는 것이 이 슬라이스의 판정이고, 아이콘은 그 위에 얹는 별개의 배선이다.
///
/// **칸 기하는 중립이 소유한다**(`dock_view_bar.slotRect`) — 여기서 다시 나누면 그린 자리와 눌리는
/// 자리의 주인이 둘이 된다.
fn appendViewBarCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    geom: maru.session.dock_layout.Geometry,
    cell_w: u32,
    cell_h: u32,
    view: maru.session.dock_panel.View,
    tk: *const maru.chrome.Tokens,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    frame_slot: *?maru.renderer.RenderFrame,
    /// 바 글리프의 **가장 위 픽셀**. 세로 중앙인지의 유일한 관측점 — 셀 행으로만 보면 짝수 줄 바에서
    /// 아래로 쏠린 것을 못 본다(사용자 지적 2026-08-25).
    glyph_top_out: *?f32,
) !void {
    const bar = geom.view_bar;
    if (bar.w == 0 or bar.h == 0) return;
    const bar_rect = maru.chrome.components.dock_view_bar.Rect{ .x = bar.x, .y = bar.y, .w = bar.w, .h = bar.h };
    var i: usize = 0;
    while (i < maru.chrome.components.dock_view_bar.slot_count) : (i += 1) {
        const r = maru.chrome.components.dock_view_bar.slotRect(bar_rect, cell_w, i) orelse continue;
        const active = i == view.slot();
        try out.append(allocator, d3d11_cells.solidCell(
            @floatFromInt(r.x),
            @floatFromInt(r.y),
            @floatFromInt(r.w),
            @floatFromInt(r.h),
            cellColor(tk, if (active) .tab_active_bg else .inset_bg),
            .{ 0, 0, 0, 0 },
        ));
    }

    // ── 아이콘 ───────────────────────────────────────────────────────────────────────────────
    //
    // **투영은 이미 있다** — `cell_text.buildDockViewBarDrawList`. 칸 기하도 그 함수가 chrome 에서
    // 받아 쓰므로 그린 자리와 눌리는 자리가 갈라지지 않는다. 여기 없던 동안 뷰 바는 **빈 사각형
    // 셋**이라 어느 칸이 무엇인지 눌러 봐야 알았다(사용자 지적 2026-08-25).
    if (frame_slot.*) |*old_frame| {
        old_frame.deinit(allocator);
        frame_slot.* = null;
    }
    const bar_cols: u16 = @intCast(bar.w / cell_w);
    const bar_rows: u16 = @intCast(@max(1, bar.h / cell_h));
    if (bar_cols == 0) return;
    const list = cell_text.buildDockViewBarDrawList(
        allocator,
        bar_cols,
        bar_rows,
        view.slot(),
        colorOf(tk, .surface_fg),
        colorOf(tk, .muted_fg),
        &.{},
    ) catch return;
    const frame = renderer_state.buildFrameFromDrawListWithRasterizer(allocator, list, builder.shaper, builder.rasterizer) catch {
        var l = list;
        l.deinit(allocator);
        return;
    };
    frame_slot.* = frame;
    try draw_host.syncAtlasTexture(pipeline, renderer_state, atlas_w, atlas_h);
    uploaded.* += draw_host.uploadFrameRegions(pipeline, frame);
    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = tk.get(.surface_fg),
        .default_bg = tk.get(.surface_bg),
    };
    const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, colors);
    defer allocator.free(native);
    // 바는 도크 안이므로 그 원점으로 옮긴다.
    maru.renderer.metal_frame.setCellsPaneOrigin(native, bar.x, bar.y);
    // **바 안에서 세로 중앙에 놓는다.** 중립은 셀 행으로 자리를 말하므로 `rows / 2` 가 최선인데,
    // 바가 **짝수 줄**이면(여기는 2 줄) 그것이 **아래 줄**이 된다 — 아이콘이 바닥에 붙어 위 여백만
    // 커 보인다(사용자 지적 2026-08-25). 반 줄은 격자로 못 적으므로 픽셀에서 잡는다. 사이드바
    // 헤더가 1.7× 아이콘에 쓰는 그 방법과 같다.
    const bar_mid_y: u32 = bar.y + (bar.h -| cell_h) / 2;
    try out.ensureUnusedCapacity(allocator, native.len);
    glyph_top_out.* = null;
    for (native) |n| {
        var c = n;
        c.row = 0;
        c.origin_y = bar_mid_y;
        const cell = win32_terminal.cellFromNative(c, cell_w, cell_h, atlas_w.*, atlas_h.*);
        if (glyph_top_out.* == null or cell.rect[1] < glyph_top_out.*.?) glyph_top_out.* = cell.rect[1];
        out.appendAssumeCapacity(cell);
    }
}

/// chrome 역할 → 터미널 색(투영 함수들이 받는 타입).
fn colorOf(tk: *const maru.chrome.Tokens, role: maru.chrome.tokens.ColorRole) maru.terminal.Color {
    return .{ .rgb = tk.get(role) };
}

/// 소스 컨트롤 표면을 도크 자리에 그린다.
///
/// **표면은 자기 뷰포트 원점(0,0) 기준으로 셀을 낸다** — 스모크에서는 그것이 창 전체였다. 도크
/// 안에 놓으려면 여기서 **평행이동**한다. 표면 안쪽을 도크 좌표로 만들지 않는 이유는, 그러면 그
/// 모듈이 "내가 창 어디에 있는가" 를 알아야 하고 그 값이 두 곳에서 관리된다.
/// 에이전트 세션 도크를 도크 자리에 그린다(W8.5b⒜).
///
/// **SCM 과 같은 순서다** — `build` 가 조립을 소유하고 여기서는 원점만 옮겨 붙인다. `Built` 를
/// 버리지 않고 슬롯에 두는 이유도 같다: 히트테스트가 그 안의 published tree 를 본다.
fn appendAgentDockCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    geom: maru.session.dock_layout.Geometry,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    cell_w: u32,
    cell_h: u32,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    agent: AgentDockInputs,
) !void {
    const area = geom.tree_content;
    if (area.w == 0 or area.h == 0) return;
    var rasterizer = builder.rasterizer;
    rasterizer.registry = &renderer_state.font_registry;
    const built = agent_surface.build(allocator, .{
        .renderer_state = renderer_state,
        .rasterizer = rasterizer,
        .pipeline = pipeline,
        .atlas_w = atlas_w,
        .atlas_h = atlas_h,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .viewport_w = area.w,
        .viewport_h = area.h,
    }, agent.state, agent.opts) catch return;
    if (agent.built.*) |*old_built| old_built.deinit();
    agent.built.* = built;
    uploaded.* += built.atlas_region_uploads;
    const dx: f32 = @floatFromInt(area.x);
    const dy: f32 = @floatFromInt(area.y);
    try out.ensureUnusedCapacity(allocator, built.cells.len);
    for (built.cells) |c| {
        var moved = c;
        moved.rect[0] += dx;
        moved.rect[1] += dy;
        out.appendAssumeCapacity(moved);
    }
}

/// 에이전트 도크가 그리는 데 필요한 것들.
const AgentDockInputs = struct {
    state: *agent_surface.State,
    opts: agent_surface.Options,
    built: *?agent_surface.Built,
};

fn appendScmDockCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    geom: maru.session.dock_layout.Geometry,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    cell_w: u32,
    cell_h: u32,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    uploaded: *usize,
    scm: ScmDockInputs,
) !void {
    const area = geom.tree_content;
    if (scm.status.len == 0 or area.w == 0 or area.h == 0) return;
    var rasterizer = builder.rasterizer;
    rasterizer.registry = &renderer_state.font_registry;
    const built = scm_surface.build(allocator, .{
        .renderer_state = renderer_state,
        .rasterizer = rasterizer,
        .pipeline = pipeline,
        .atlas_w = atlas_w,
        .atlas_h = atlas_h,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .viewport_w = area.w,
        .viewport_h = area.h,
    }, scm.state, scm.opts) catch return;
    // **버리지 않고 슬롯에 둔다** — 이 표면의 히트테스트는 `Built` 안의 published tree 를 본다.
    // 버리면 화면에는 그려지는데 **눌리지 않는** 죽은 컨트롤이 된다(§2m.31 이 이름 붙인 실패).
    if (scm.built.*) |*old_built| old_built.deinit();
    scm.built.* = built;
    uploaded.* += built.atlas_region_uploads;
    const dx: f32 = @floatFromInt(area.x);
    const dy: f32 = @floatFromInt(area.y);
    try out.ensureUnusedCapacity(allocator, built.cells.len);
    for (built.cells) |c| {
        var moved = c;
        moved.rect[0] += dx;
        moved.rect[1] += dy;
        out.appendAssumeCapacity(moved);
    }
}

/// 도크 자리를 채우는 셀 — **배경과 디바이더**. W8.7a 는 여기까지다(파일 트리는 ⒜2 — 그것은
/// 터미널과 **아틀라스를 나눠 써야** 하므로 별개의 배선이다).
///
/// 디바이더를 **그린다**는 것이 중요하다: 안 그리면 터미널과 도크가 같은 배경색으로 이어져 창이
/// 갈렸다는 사실이 화면에 안 보이고, 사각형이 어긋나도 눈에 안 띈다.
fn rebuildDockCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    geom: maru.session.dock_layout.Geometry,
    tk: *const maru.chrome.Tokens,
) !void {
    out.clearRetainingCapacity();
    if (geom.dock.w == 0 or geom.dock.h == 0) return;
    try out.append(allocator, d3d11_cells.solidCell(
        @floatFromInt(geom.dock.x),
        @floatFromInt(geom.dock.y),
        @floatFromInt(geom.dock.w),
        @floatFromInt(geom.dock.h),
        cellColor(tk, .surface_bg),
        .{ 0, 0, 0, 0 },
    ));
    if (geom.divider.w != 0 and geom.divider.h != 0) {
        try out.append(allocator, d3d11_cells.solidCell(
            @floatFromInt(geom.divider.x),
            @floatFromInt(geom.divider.y),
            @floatFromInt(geom.divider.w),
            @floatFromInt(geom.divider.h),
            cellColor(tk, .divider),
            .{ 0, 0, 0, 0 },
        ));
    }
}

/// 창 하나를 **터미널과 도크로 가르는** 기하. 계산은 중립이 하고(`session/dock_layout.compute`)
/// 여기서는 Windows 가 아는 값(창 크기·셀 크기)만 채운다.
///
/// **타이틀바 띠는 아직 0 이다** — 창이 네이티브 캡션을 쓴다(W8.8⒝ 가 프레임리스로 바꾼다).
/// 사이드바 폭은 이제 호출자가 준다(W8.8⒜).
fn dockGeometryFor(
    width_px: u32,
    height_px: u32,
    cell_w: u32,
    cell_h: u32,
    visible: bool,
    size_pt: u32,
    view: maru.session.dock_panel.View,
    /// 왼쪽 사이드바 폭(px). 0 이면 사이드바가 없다 — `compute` 가 작업영역을 그만큼만 민다.
    sidebar_width_px: u32,
    /// 상단 드래그 띠 높이(px). 프레임리스 창이 캡션을 지운 만큼 작업영역을 아래로 들인다.
    titlebar_px: u32,
    /// 하단 상태표시줄 높이(px). **창 전폭**이라 작업영역 밖에 살고, `compute` 가 창 높이에서 **먼저**
    /// 깎는다 — 그래서 이 값 하나로 터미널 행·도크·사이드바 뷰포트가 전부 함께 줄어든다(W8.9).
    status_bar_px: u32,
) maru.session.dock_layout.Geometry {
    const dock_layout = maru.session.dock_layout;
    return dock_layout.compute(.{
        .backing_width_px = width_px,
        .backing_height_px = height_px,
        .sidebar_width_px = sidebar_width_px,
        .titlebar_height_px = titlebar_px,
        .cell_width_px = cell_w,
        .cell_height_px = cell_h,
        .scale_milli = 1000,
        .divider_px = dock_layout.dividerGrabBandPx(1000),
        .side = .right,
        .size_pt = size_pt,
        .visible = visible,
        .view = view,
        .view_bar_px = cell_h * 2,
        .status_bar_px = status_bar_px,
    });
}

fn runWin32Terminal(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer, max_spins: ?usize) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-terminal-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    // ── 사용자 config ──────────────────────────────────────────────────────────────────────
    //
    // **폰트보다 먼저 읽는다** — `font.family`·`font.fallback`·`font.size` 가 래스터라이저 생성 인자다.
    // 없거나 못 읽으면 기본값이다(forgiving: 설정 파일이 없어도 터미널은 정상 동작해야 한다).
    //
    // **`Parsed`(arena)를 세션 내내 들고 있어야 한다** — 리졸버가 바인딩 슬라이스를, 래스터라이저와
    // 코어가 문자열 값을 arena 에서 **빌린다**. 먼저 해제하면 dangling 이다.
    var loaded = try maru.config.loader.loadDefault(io, allocator);
    defer loaded.deinit();
    const cfg = loaded.config;
    // **hex 문자열을 여기서 파싱하지 않는다.** `appearance.resolve` 가 색 해석·대비 보정·기본값 폴백을
    // 소유한다(macOS 도 같은 함수를 쓴다). 실패하면 값이 잘못된 것이므로 **조용히 기본값으로 접지 않고**
    // 알린 뒤 빌트인으로 간다 — 키바인딩 검증과 같은 규율이다.
    const appearance = maru.config.appearance.resolve(cfg) catch |err| blk: {
        try stderr.print("  warning: theme colors are invalid({s}) — falling back to built-ins\n", .{@errorName(err)});
        break :blk try maru.config.appearance.resolve(.{});
    };

    // ── 폰트와 셀 격자 ─────────────────────────────────────────────────────────────────────
    //
    // **config 값을 그대로 넘긴다** — 여기서 이름을 박으면 §2e 의 티어가 죽는다.
    //
    // **기본값이 비어 있지 않다는 점에 주의한다**(`config/theme.zig`: `family = "JetBrains Mono"`,
    // `fallback = "Jetendard"`). `fontCandidates` 는 설정값을 **맨 앞에** 놓고 그다음이 티어이므로,
    // config 파일이 없어도 JetBrains Mono 를 먼저 찾고 없을 때 Cascadia Mono 로 내려간다. 이 기계에서
    // `font_family=Cascadia Mono` 로 보이는 것은 그 폰트가 없어서지 "빈 값이라 티어가 골라서" 가 아니다.
    // `Jetendard` 는 macOS 번들 한글 폰트라 Windows 에서는 열리지 않고 폴백 사슬 앞에 무해하게 남는다.
    var raster = dwrite_font.Rasterizer.create(allocator, cfg.font.family, cfg.font.fallback, cfg.font.size) catch |err| {
        try stderr.print("maru win32-terminal-smoke: could not set up the font({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(dwrite_font.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer raster.destroy();
    const cell_w = raster.metrics.width_px;
    const cell_h = raster.metrics.height_px;

    const scratch = try allocator.alloc(u8, win32_text.NeutralRasterizer.scratchSizeFor(cell_w * 2, cell_h));
    defer allocator.free(scratch);
    const builder = win32_terminal.FrameBuilder{
        .shaper = .{ .raster = raster },
        .rasterizer = .{ .raster = raster, .scratch = scratch },
    };

    // ── 창·표시 경로 ───────────────────────────────────────────────────────────────────────
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.2c terminal)");
    var window = win32_window.Window.create(allocator, title, 1000, 640) catch |err| {
        try stderr.print("maru win32-terminal-smoke: could not create the window({s}, Win32 error {d})\n", .{ @errorName(err), win32_window.last_create_error });
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  error 8 (ERROR_NOT_ENOUGH_MEMORY) usually means the desktop heap is exhausted — check how many processes this session has.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    const initial = window.clientSize() orelse win32_window.ClientSize{ .width_px = 1000, .height_px = 640 };
    var present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
        try stderr.print("maru win32-terminal-smoke: could not set up the present path({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer present.destroy();
    window.present.opaque_handle = @ptrCast(present);

    // ── 창을 터미널과 도크로 가른다 (§2m.31) ────────────────────────────────────────────────
    //
    // **기하는 중립이 정한다**(`session/dock_layout.compute`) — macOS 가 쓰는 그 함수다. Windows 가
    // 자기 산수로 다시 나누면 두 플랫폼의 도크 폭·디바이더 두께가 조용히 갈린다.
    // 도크 상태. **⒞ 슬라이스가 이 둘을 움직인다**(디바이더 드래그·숨기기) — 지금은 고정이다.
    const dock_visible = true;
    // **⒞ 가 이것을 움직인다** — 디바이더를 끌면 폭이 바뀐다. 0 은 "뷰가 정한 기본 폭" 센티널이다.
    var dock_size_pt: u32 = 0;
    // 도크가 지금 무엇을 보이는가. 뷰 바의 칸을 누르면 바뀐다(W8.7c2).
    var dock_view: maru.session.dock_panel.View = .explorer;
    // **사이드바 폭은 config 가 정한다**(`sidebar.width`, pt). 배율이 1 이라 pt 가 곧 px 다 —
    // 포트 전체에 DPI 인지가 없다(§2m.35 의 한계와 같은 축).
    const sidebar_w: u32 = cfg.sidebar.width_pt;
    // **지금 클라이언트 크기.** 디바이더 드래그가 기하를 다시 계산할 때 이 값이 필요하다 —
    // `initial` 은 시작 값이라 창을 키운 뒤 쓰면 도크가 옛 창 기준으로 선다.
    // ── 프레임리스 창 (W8.8⒝) ───────────────────────────────────────────────────────────────
    //
    // **Windows 관례를 따른다**(§2m.37 의 결정): 캡션 버튼 ─ ☐ ✕ 를 띠 **오른쪽 끝**에 우리가
    // 그리고, 나머지 빈 곳은 `HTCAPTION` 이라 OS 가 끌어 준다(더블클릭 최대화·Aero Snap 포함).
    //
    // 띠 높이는 **셀에서 유도한다** — 하드코딩하면 폰트를 키웠을 때 버튼만 안 따라온다.
    const titlebar_px: u32 = @max(cell_h * 2, 32);
    const caption_btn_w: u32 = @max(cell_w * 5, 46);
    const caption_buttons_px: u32 = caption_btn_w * 3;
    // **띠 왼쪽 사이드바 폭도 우리가 받는다** — 그 자리가 헤더의 아이콘 줄이다(§2m.37 의 모양).
    window.setFrameless(titlebar_px, caption_buttons_px, sidebar_w);
    // ── 하단 상태표시줄 (W8.9) ──────────────────────────────────────────────────────────────
    //
    // **치수는 중립 잎이 정한다**(`status_bar_metrics`) — macOS 와 같은 함수다. 여기서 산수를 다시
    // 적으면 같은 창의 두 OS 가 다른 높이를 쓰고, 그때 갈리는 것은 바 하나가 아니라 **터미널 행 수**다
    // (그 높이가 작업영역을 깎는다).
    //
    // **끄는 판정만 여기 있다** — `status-bar.show` 는 config 이고 중립 잎은 config 를 모른다.
    // 게이트가 이 한 자리라 끄면 작업영역·도크·사이드바가 전부 자동으로 되돌아온다(계약 §2).
    const status_bar_px: u32 = if (cfg.status_bar.show) maru.status_bar_metrics.heightPx(cell_h, 1000) else 0;

    var client_w = initial.width_px;
    var client_h = initial.height_px;
    var geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px, status_bar_px);

    // **격자는 창이 아니라 터미널 사각형에서 나온다.** 창 폭으로 유도하면 셸이 그만큼 넓다고 믿어
    // 긴 줄이 도크 아래로 흘러 들어간다(그리는 자리는 잘려도 셸의 줄바꿈이 어긋난다).
    const start = win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h) orelse
        maru.terminal.Size{ .cols = 80, .rows = 24 };
    // 판정용 기준값 — **사각형에서 곧바로** 나온 격자. `start` 와 갈리면 격자를 창에서 유도한 것이다.
    const want_cols: u16 = @intCast(geom.terminal.w / cell_w);
    const want_rows: u16 = @intCast(geom.terminal.h / cell_h);
    const script = maru.app.fixture_script.interactiveEcho(@import("builtin").os.tag);
    // **셸도 config에서 온다** — `shell.command`가 1순위, 없으면 `shell.windows-shell`이 고른 티어.
    // 이 배선이 없던 동안 두 키는 파싱·검증만 되고 spawn까지 가지 않았다(실측: config가 `cmd`를 지정했는데
    // 자식은 `pwsh.exe`였다). 폰트를 바로 위에서 `cfg`로 뽑으면서 셸만 기본값이던, 읽어 놓고 안 쓰던 자리다.
    //
    // fixture는 이 선택에 안 흔들린다 — `interactiveEcho(.windows)`는 인자가 비어 있고 입력이
    // `echo …\r\nexit\r\n`이라 cmd·PowerShell 양쪽에서 같게 돈다.
    const command = maru.pty.resolveShell(cfg.shell.command, maru.windowsShellKindOf(cfg.shell.windows_shell));
    // **`shell.args` 도 config 에서 온다.** 기본값이 OS 별로 갈리므로(`defaultShellArgsFor`) Windows
    // 에서는 비어 있고, 사용자가 적었을 때만 값이 온다. 한때 기본이 `&.{"-i"}` 하나뿐이라 배선할 수
    // 없었다 — PowerShell 5.1 이 `-i` 를 `-InputFormat` 축약으로 읽고 값을 요구해 **셸이 안 떴다**.
    //
    // fixture 인자는 Windows 에서 비어 있어(`interactiveEcho(.windows)`) 사용자가 안 적으면 결과가
    // 예전과 같다. POSIX fixture 의 `-i` 는 이 함수가 Windows 전용이라 여기 안 온다.
    const args = if (cfg.shell.args.len > 0) cfg.shell.args else script.args;

    // ── 세션 목록 (W8.8⒞) ───────────────────────────────────────────────────────────────────
    //
    // **표면과 PTY 는 힙에 고정한다.** `AppWindow` 의 doc 이 그 이유를 적어 뒀다 — `SurfaceRuntime`
    // 이 `*Surface` 를 라우팅에 보관하고 리더 스레드가 `&reader` 를 잡으므로, 목록이 realloc 될 때
    // 본체가 움직이면 그 포인터들이 dangling 된다. 목록에는 **포인터만** 모은다.
    //
    // **세션마다 PTY 하나다.** `LivePtySession` 은 링크를 하나만 든다(`self.link`). macOS 도 Term
    // 마다 세션·pump 를 따로 들고 tick 이 **전부** 드레인한다 — 같은 모양을 쓴다.
    // ── 연 파일 (W8.13) ────────────────────────────────────────────────────────────────────
    //
    // **창당 경로 유일성**(file-panel.md §1)을 지킨다 — 같은 파일을 다시 누르면 새로 열지 않고
    // 그것으로 간다. 그 불변식이 없으면 트리를 두 번 눌렀을 때 같은 파일이 카드 둘이 된다.
    // ── 사이드바 검색 (W8.15) ──────────────────────────────────────────────────────────────
    //
    // **모델은 중립이 소유한다** — `overlay_input.OverlayInput` 은 find·palette·rename·사이드바
    // 검색이 **공유**하는 것이다(그 파일 머리말). 커밋 글자와 IME 조합을 따로 들고 있어, 조합 중에
    // 검색어가 흔들리지 않는다.
    var search: maru.chrome.components.overlay_input.OverlayInput = .{};
    defer search.deinit(allocator);
    // **에이전트 도크는 자기 검색을 따로 든다.** 사이드바와 한 상자를 쓰면 한쪽을 치는 동안 다른
    // 쪽 목록이 같이 걸러진다 — 두 목록은 서로 다른 것을 찾는다.
    var agent_search: maru.chrome.components.overlay_input.OverlayInput = .{};
    defer agent_search.deinit(allocator);
    var agent_search_focused = false;
    var agent_search_chars: usize = 0;
    var agent_search_focus_changes: usize = 0;
    // 키가 **누구 것인가**. 이것이 없으면 검색 줄을 눌러도 글자가 셸로 간다.
    var search_focused = false;
    var search_focus_changes: usize = 0;
    var search_chars: usize = 0;
    var open_files: std.ArrayList(OpenFile) = .empty;
    defer {
        for (open_files.items) |*f| f.deinit(allocator);
        open_files.deinit(allocator);
    }
    var active_view: ActiveView = .{ .terminal = 0 };
    var file_opens: usize = 0;
    var file_reopens: usize = 0;
    var file_rejects: usize = 0;
    var last_reject: std.meta.Tag(OpenOutcome) = .opened;
    var file_view_switches: usize = 0;
    var close_clicks: usize = 0;
    // **닫은 뒤에 무엇이 남았나.** 개수만 보면 색인이 밀려 **엉뚱한 것이 지워져도** 초록이다.
    var close_judgeable = false;
    var close_files_before: usize = 0;
    var close_files_after: usize = 0;
    // **이름을 소유한다.** 빌리면 닫는 순간 그 메모리가 사라져 판정이 **해제된 자리**를 읽는다 —
    // 뮤턴트에서 실제로 깨진 글자가 찍혔다(§2m.71 ⑴ 과 같은 계급).
    var close_want_buf: [256]u8 = undefined;
    var close_want_len: usize = 0;
    var close_got_buf: [256]u8 = undefined;
    var close_got_len: usize = 0;
    var close_view_ok = false;
    var close_click_x: i32 = 0;
    // **거른 뒤에 무엇이 남았나.** 개수만 보면 "전부 사라졌다" 도 초록이다 — 세션과 파일을 갈라 센다.
    var search_judgeable = false;
    var search_focused_after_click = false;
    var search_cards_before: usize = 0;
    var search_cards_after: usize = 0;
    var search_cards_restored: usize = 0;
    var search_sessions_after: usize = 0;
    var search_files_after: usize = 0;
    var search_query_drawn: usize = 0;
    var asearch_judgeable = false;
    var asearch_focused = false;
    var asearch_items_before: usize = 0;
    var asearch_items_after: usize = 0;
    var asearch_items_restored: usize = 0;
    // **닫은 뒤에 무엇이 남았나.** 개수만 보면 엉뚱한 세션이 죽어도 초록이다 — 남은 첫 이름을 본다.
    var sclose_judgeable = false;
    var sclose_sessions_before: usize = 0;
    var sclose_sessions_after: usize = 0;
    var sclose_tabs_before: usize = 0;
    var sclose_tabs_after: usize = 0;
    var sclose_second_name: [24]u8 = undefined;
    var sclose_second_name_len: usize = 0;
    var sclose_first_name: [24]u8 = undefined;
    var sclose_first_name_len: usize = 0;
    var sclose_active_ok = false;
    var sclose_pump_rebound = false;
    var sclose_active_want: [24]u8 = undefined;
    var sclose_active_want_len: usize = 0;
    var sclose_active_name: [24]u8 = undefined;
    var sclose_active_name_len: usize = 0;
    var idcheck_judgeable = false;
    var idcheck_dups: usize = 0;
    var idcheck_count: usize = 0;
    var idcheck_spawned = false;
    var idcheck_err: [48]u8 = undefined;
    var idcheck_err_len: usize = 0;
    var multi_closes: usize = 0;
    var multi_sessions: usize = 0;
    var multi_tabs: usize = 0;
    var multi_dups: usize = 0;
    var multi_active_ok = false;
    var busy_judgeable = false;
    var busy_result_busy = false;
    var busy_sessions_before: usize = 0;
    var busy_sessions_after: usize = 0;
    var busy_tabs_before: usize = 0;
    var busy_tabs_after: usize = 0;
    var busy_active_before: usize = 0;
    var busy_active_after: usize = 0;
    var busy_still_alive = false;
    // **모달이 뜨고, 그려지고, 승낙하면 닫히는가.** 셋을 함께 본다 — 상태만 서면 화면이 안 답하고,
    // 그리기만 되면 승낙이 아무 일도 안 한다.
    var modal_judgeable = false;
    var modal_open_after_click = false;
    var modal_open_after_accept = true;
    var modal_cells: usize = 0;
    var modal_sessions_before: usize = 0;
    var modal_sessions_while_open: usize = 0;
    var modal_sessions_after: usize = 0;
    var cancel_judgeable = false;
    var cancel_open_before = false;
    var cancel_open_after = true;
    var cancel_sessions_before: usize = 0;
    var cancel_sessions_after: usize = 0;
    var capmodal_judgeable = false;
    var capmodal_before = false;
    var capmodal_after = false;
    var probe_victim_id: u64 = 0;
    // 모달이 창 크기 변화를 따라오는가.
    var resize_cells_before: usize = 0;
    var resize_cells_after: usize = 0;
    var resize_center_before: i64 = 0;
    var resize_center_after: i64 = 0;
    var resize_client_before: u32 = 0;
    var resize_client_after: u32 = 0;
    var resize_open_after = false;
    var cycle_opens: usize = 0;
    var cycle_closes: usize = 0;
    var cycle_first_cells: usize = 0;
    var cycle_last_cells: usize = 0;
    var shift_judgeable = false;
    var shift_target_survived = true;
    var file_closes: usize = 0;
    var session_closes: usize = 0;
    var session_close_busy: usize = 0;
    var session_close_last: usize = 0;
    var editor_frames: usize = 0;
    var editor_build_failures: usize = 0;
    var editor_scrolls: usize = 0;
    var editor_clamps: usize = 0;
    var editor_hscrolls: usize = 0;
    var editor_hdrags: usize = 0;
    // **막대를 끌 수 있어야 한다.** 보이는데 안 잡히면 그것은 장식이다(#2665 가 트리 셰브런에서
    // 받은 그 지적). 수명·흡수·중복 억제 규율은 중립이 소유한다(`scrollbar.HorizontalDrag`).
    var hbar_drag: maru.chrome.components.editor_view.scrollbar.HorizontalDrag = .{};
    var hbar_drag_release = false;
    var editor_atlas_growths: usize = 0;
    var editor_cells_outside_last: usize = 0;
    var editor_cells_outside_max: usize = 0;
    var editor_last_digest: u64 = 0;
    var hscroll_judgeable = false;
    var hscroll_col_before: u16 = 0;
    var hscroll_col_after: u16 = 0;
    var hscroll_max_cols: u32 = 0;
    var hscroll_digest_before: u64 = 0;
    var hscroll_digest_after: u64 = 0;
    var editor_last_hbar: ?maru.chrome.components.editor_view.scrollbar.HorizontalGeometry = null;
    var hbar_before: ?maru.chrome.components.editor_view.scrollbar.HorizontalGeometry = null;
    var hbar_after: ?maru.chrome.components.editor_view.scrollbar.HorizontalGeometry = null;
    var hend_col: u16 = 0;
    var hend_max_cols: u32 = 0;
    var hend_hbar: ?maru.chrome.components.editor_view.scrollbar.HorizontalGeometry = null;
    var hend_hmax_before: u16 = 0;
    var hoob_judgeable = false;
    var hoob_col_after: u16 = 0;
    var hoob_hmax: u16 = 0;
    var hoob_cells: usize = 0;
    var hdrag_judgeable = false;
    var hdrag_col_before: u16 = 0;
    var hdrag_col_after: u16 = 0;
    var hdrag_thumb_before: f32 = 0;
    var hdrag_thumb_after: f32 = 0;
    var hdrag_drags: usize = 0;
    var hterm_judgeable = false;
    var hterm_scrolls_before: usize = 0;
    var hterm_scrolls_after: usize = 0;
    var hterm_reports_before: usize = 0;
    var hterm_reports_after: usize = 0;
    var axis_judgeable = false;
    var axis_col_before: u16 = 0;
    var axis_col_after: u16 = 0;
    var axis_line_before: usize = 0;
    var axis_line_after: usize = 0;
    var jump_judgeable = false;
    var jump_col_before: u16 = 0;
    var jump_col_after: u16 = 0;
    var jump_local_x: f32 = 0;
    var jump_on_thumb_before = false;
    var jump_on_thumb_after = false;
    var reveal_judgeable = false;
    var reveal_slot: usize = 0;
    var reveal_slot_after: usize = 0;
    var reveal_visible_before = false;
    var reveal_visible_after = false;
    var reveal_off_before: u32 = 0;
    var reveal_off_after: u32 = 0;
    var reveal_count: usize = 0;
    var reveal_path_buf: [512]u8 = undefined;
    var reveal_path_len: usize = 0;
    var reveal_digest_before: u64 = 0;
    var reveal_digest_after: u64 = 0;
    var dclamp_row: usize = 0;
    var dclamp_expanded = false;
    var dclamp_judgeable = false;
    var dclamp_off_before: u32 = 0;
    var dclamp_off_after: u32 = 0;
    var dclamp_rows_before: usize = 0;
    var dclamp_rows_after: usize = 0;
    var dclamp_drawn_after: u16 = 0;
    var dclamp_draw_start_after: usize = 0;
    var dock_clamps: usize = 0;
    var leak_judgeable = false;
    var leak_sidebar_before: u32 = 0;
    var leak_sidebar_after: u32 = 0;
    var leak_dock_before: u32 = 0;
    var leak_dock_after: u32 = 0;
    var cap_cards: usize = 0;
    var cap_rows: usize = 0;
    var cap_off: u32 = 0;
    var cap_last_visible = false;
    var cap_first_visible: usize = 0;
    var cap_visible: usize = 0;
    var clip_partial: u32 = 0;
    var clip_over: usize = 0;
    var clip_clipped: usize = 0;
    var scroll_judgeable = false;
    var scroll_first_before: usize = 0;
    var scroll_first_after: usize = 0;
    var scroll_digest_before: u64 = 0;
    var scroll_digest_after: u64 = 0;
    var spawn_while_file_judgeable = false;
    var spawn_while_file_sessions_before: usize = 0;
    var spawn_while_file_sessions_after: usize = 0;
    var spawn_while_file_shows_terminal = false;
    // **파일을 보는 중에 친 글자가 어디로 가나.** 화면에 문서가 떠 있는데 글자가 **안 보이는 셸**로
    // 들어가면, 사용자는 자기가 무엇을 치고 있는지 모른 채 친다.
    var keys_while_file: usize = 0;
    var keys_to_terminal_while_file: usize = 0;
    var keytest_judgeable = false;
    // 문서 위 클릭이 터미널 선택·리포트로 새는가.
    var mouse_over_file: usize = 0;
    // **리포트 수로는 못 잰다.** 마우스 리포트는 트래킹이 켜져야 나가는데 스모크의 셸은 꺼져 있어,
    // 삼키지 않아도 0 이다(실측: 뮤턴트가 초록으로 통과했다). 트래킹이 꺼진 상태의 진짜 누출은
    // **터미널에 선택이 생기는 것**이라 그것을 직접 본다.
    var mouse_sel_before = false;
    var mouse_sel_after = false;
    var mousetest_judgeable = false;
    var oob_judgeable = false;
    var divfile_judgeable = false;
    var divfile_dock_w_before: u32 = 0;
    var divfile_dock_w_after: u32 = 0;
    var oob_first_after: usize = 0;
    var oob_rows_after: usize = 0;
    var oob_lines: usize = 0;
    var editor_last_cells: usize = 0;
    var editor_last_rows: usize = 0;
    // **파일이 진짜 떴는가.** 카드가 늘어난 것만 보면 속 빈다 — 편집기가 **그 파일의 줄**을 그렸는지,
    // 그리고 같은 줄을 다시 눌렀을 때 카드가 **안 늘어나는지**(창당 경로 유일성)를 함께 본다.
    var open_judgeable = false;
    // **경로를 소유한다.** 행이 든 슬라이스는 **트리 노드**의 것이라, 재스캔이 그 항목을 갈아
    // 끼우면 죽는다 — W8.12 로 재스캔이 임의 프레임에 오게 되면서 더 위험해졌다. 그리고 이 값이
    // 죽으면 두 번째 클릭이 대상을 못 찾아 **유일성 검사가 초록인 채 속이 빈다**(실측: `reopens=0`
    // 인데 `open_file_ok=true`).
    var open_target_buf: [512]u8 = undefined;
    var open_target_len: usize = 0;
    var open_files_after_first: usize = 0;
    var open_files_after_second: usize = 0;
    var open_editor_cells: usize = 0;
    var open_editor_rows: usize = 0;
    var open_showing_file = false;
    var open_sidebar_digest_before: u64 = 0;
    var open_sidebar_digest_after: u64 = 0;
    var md_judgeable = false;
    var md_files_before: usize = 0;
    var md_files_after: usize = 0;
    var md_rejects_before: usize = 0;
    var md_rejects_after: usize = 0;
    var md_reason: std.meta.Tag(OpenOutcome) = .opened;
    // 편집기 op 버퍼는 **한 번만 잡는다** — 프레임마다 4096 개를 새로 잡으면 그것이 곧 프레임 비용이다.
    const ops_buf = try allocator.alloc(maru.chrome.draw.Op, 4096);
    defer allocator.free(ops_buf);
    // **세션 번호는 단조 증가한다** — 길이에서 뽑으면 닫은 뒤 번호가 되살아난다(위 함수 doc).
    // ── 확인 모달 (W8.16b) ─────────────────────────────────────────────────────────────────
    //
    // **컴포넌트는 중립이 이미 갖고 있다**(`chrome/components/confirm.zig`) — macOS 도 AppKit 대화상자가
    // 아니라 이것을 그린다. 메시지·버튼은 **키로만** 온다(계약 §7.2: 리터럴을 넘기면 컴파일이 막힌다).
    //
    // Windows 에 없던 것은 셋이다: 그리는 배선, 모달이 떠 있는 동안의 **입력 주인**, 그리고 보류 상태.
    var confirm_state: maru.chrome.components.confirm.State = .{};
    // 확인을 기다리는 닫기 대상. **번호가 아니라 id 다.**
    //
    // 처음에는 목록 번호를 들었다 — 모달이 입력을 삼키므로 그동안 목록이 안 바뀐다고 봤기 때문이다.
    // 그런데 **한 줄만 바뀌면**(셸이 끝난 세션을 자동으로 걷어내는 등) 밀린다. 실험으로 모달이 뜬
    // 동안 다른 세션을 지워 보니 승낙이 **엉뚱한 세션**을 닫았다(적대적 검증 3회차:
    // `pending_idx_target_survives=true` — 닫으라고 한 것이 살아남았다).
    //
    // id 는 단조 증가라 재사용되지 않는다(§2m.78 ⑵ 가 그것을 고쳤다). 승낙할 때 **그 id 를 다시
    // 찾아** 번호를 푼다 — macOS `confirm_accept` 가 범위를 다시 푸는 것과 같은 규율이다.
    var pending_close_id: ?u64 = null;
    var confirm_shows: usize = 0;
    var confirm_accepts: usize = 0;
    var confirm_cancels: usize = 0;
    // 마우스로 고른 것은 **다음 프레임에** 실행한다 — 이벤트 루프 안에서 세션을 지우면 그 프레임의
    // 나머지가 사라진 것을 만진다.
    var confirm_pending_click: ?maru.chrome.components.confirm.Action = null;
    var confirm_cells_drawn: usize = 0;
    var confirm_draw_failures: usize = 0;
    var confirm_unpainted: usize = 0;
    var confirm_center_x: i64 = 0;
    var confirm_frame: ?maru.renderer.RenderFrame = null;
    defer if (confirm_frame) |*f| f.deinit(allocator);
    var next_session_id: usize = 0;
    var sessions: std.ArrayList(*WinSession) = .empty;
    defer {
        for (sessions.items) |s| s.destroy(allocator);
        sessions.deinit(allocator);
    }
    var tab_ptrs: std.ArrayList(*maru.session.surface.Surface) = .empty;
    defer tab_ptrs.deinit(allocator);

    // **앱 수준 config 를 코어에 한 번에 건다.** 스크롤백 길이·팔레트·기본 전경/배경·모호폭/이모지폭·
    // 커서 모양이 여기서 온다 — 예전에는 전부 코어 기본값이라 `scrollback.lines` 를 바꿔도 무동작이었다.
    //
    // **`set_runtime_config` 한 묶음으로 보낸다.** 값마다 명령을 따로 보내면 자식의 첫 출력이 그 사이에
    // 끼어 **옛 설정으로 파싱**되는 자리가 생긴다(macOS 가 같은 이유로 이 묶음을 쓴다). 리더가 뜨기 전에
    // 거는 것도 같은 이유다.
    //
    // **셀 크기도 함께 준다.** 코어가 링크 판정·마우스 좌표에 셀 크기를 쓰는데, 안 주면 기본값으로 굳어
    // 폰트를 키워도 그 계산만 옛 값을 본다.
    var app_window: maru.session.window.AppWindow = .{ .tabs = &.{} };

    var runtime = maru.app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();

    // **`size` 는 spawn 시점에 덮어쓴다** — 여기 박아 두면 창을 키운 뒤 만든 세션이 **옛 격자**를
    // 받는다(실측: `sessions_wrong_size=1`).
    var spawn_opts = WinSession.SpawnOptions{
        .io = io,
        .command = command,
        .args = args,
        .size = start,
        .cfg = cfg,
        .appearance = appearance,
        .cell_w = cell_w,
        .cell_h = cell_h,
    };
    // 첫 세션. 실패하면 창을 띄울 이유가 없다.
    try spawnWinSession(allocator, &sessions, &tab_ptrs, &app_window, &runtime, &next_session_id, spawn_opts);

    // **pump 는 세션이 소유한다.** `AppFrameLoop` 는 pump 하나만 받으므로 그것을 첫 세션 것으로 두고
    // **재바인딩하지 않는다** — macOS 가 같은 이유로 같은 짓을 한다(`frame_loop.pump` 주석). 매 tick 은
    // `tickAfterDrainWithFrameBuilder` 로 들어가고, 드레인은 **우리가 전부** 돈다.
    var pump = sessions.items[0].pump;
    // **폰트가 정한 셀 크기를 렌더러에 알려 준다.** 기본값(0)으로 두면 아틀라스가 슬롯 크기를 다른 값으로
    // 추정해 글리프가 아래에서 잘린다 — 실측으로 겪었다(베이스라인 17인데 슬롯이 그보다 낮았다).
    // `glyph_cell_width_px`는 자간과 무관한 자연폭이다. 지금은 자간이 0이라 grid advance와 같다.
    var renderer_state = maru.renderer.RendererState.init(allocator, .{
        .text = .{
            // **래스터라이저와 같은 크기를 쓴다.** 여기만 18 로 박혀 있어 config 를 바꾸면(또는 기본
            // 14 로만 와도) 글리프는 그 크기로 그려지는데 캐시 키·아틀라스 슬롯은 18 로 잡혔다 —
            // `GlyphCacheKey` 가 실제 크기를 구분 못 하고, 메트릭 없는 폴백 슬롯이 엉뚱한 변으로 선다.
            // f32→u16 변환(NaN·범위 보정)은 `textConfigFromFontSize` 가 단일 출처다.
            .font_size_px = maru.renderer.textConfigFromFontSize(cfg.font.size, 1).font_size_px,
            .device_scale = 1,
            .cell_width_px = @intCast(cell_w),
            .glyph_cell_width_px = @intCast(cell_w),
            .cell_height_px = @intCast(cell_h),
        },
    });
    defer renderer_state.deinit();
    var loop = maru.app.AppFrameLoop.init(allocator, &app_window, &runtime, &pump, &renderer_state, io);

    // ── 셀 파이프라인 — 아틀라스는 **비워 두고** 프레임마다 부분 업로드한다 ────────────────
    var atlas_w = renderer_state.atlas.config.atlas_width_px;
    var atlas_h = renderer_state.atlas.config.atlas_height_px;
    var pipeline = d3d11_cells.CellPipeline.createEmptyAtlas(allocator, present.device, present.context, atlas_w, atlas_h) catch |err| {
        try stderr.print("maru win32-terminal-smoke: could not set up the cell pipeline({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_cells.last_hresult)) });
        if (d3d11_cells.shaderError().len > 0)
            try stderr.print("  shader compiler: {s}\n", .{d3d11_cells.shaderError()});
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer pipeline.destroy();

    // ── 도크 내용: 파일 트리 (W8.7a2) ───────────────────────────────────────────────────────
    //
    // **스캔은 한 번, 프레임은 기하·아틀라스가 바뀔 때 다시.** 트리 내용은 안 변하지만 프레임의
    // 아틀라스 UV 는 아틀라스가 커지면 무효가 된다 — 그때 다시 안 지으면 도크 글자가 엉뚱한
    // 글리프로 바뀐다.
    var dock_tree = maru.session.file_tree.Tree.init(allocator);
    defer dock_tree.deinit();
    var dock_rows: std.ArrayList(maru.session.file_tree.Row) = .empty;
    defer dock_rows.deinit(allocator);
    var dock_root: ?[]u8 = null;
    defer if (dock_root) |r| allocator.free(r);
    // **스캔 실패는 치명적이지 않다** — 도크가 비고 터미널은 그대로 돈다. 앱을 못 띄울 이유가 아니다.
    var dock_scan_ok = false;
    // **백엔드는 앱이 사는 동안 산다.** 예전에는 이 블록 안에서 만들고 바로 버렸는데, 그러면 시작
    // 스캔만 되고 **런타임에 폴더를 펼칠 수가 없다**(트리가 lazy 라 펼칠 때 그때 읽는다).
    var tree_backend: ?file_tree_backend.Backend = file_tree_backend.Backend.init(allocator, io) catch null;
    defer if (tree_backend) |*b| b.deinit();
    scan: {
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_native = root_buf[0..(std.Io.Dir.cwd().realPath(io, &root_buf) catch break :scan)];
        const root_path = maru.path_shape.normalizeSeparators(allocator, root_native) catch break :scan;
        dock_root = root_path;
        dock_tree.replaceExplicitRoots(&.{root_path}) catch break :scan;

        const backend = if (tree_backend) |*b| b else break :scan;
        var validated = (file_tree_backend.validateRootSnapshot(allocator, io, root_path) catch break :scan) orelse break :scan;
        var validated_owned = true;
        defer if (validated_owned) validated.deinit(allocator, io);
        const validated_dir = validated.dir orelse break :scan;
        validated.dir = null;
        const owned = allocator.dupe(u8, root_path) catch break :scan;
        if (!backend.submitValidatedRootScan(owned, 0, validated_dir)) {
            allocator.free(owned);
            validated_dir.close(io);
            break :scan;
        }
        validated.deinit(allocator, io);
        validated_owned = false;

        var scan_rounds: usize = 0;
        while (scan_rounds < 4000) : (scan_rounds += 1) {
            if (backend.takeResult()) |taken| {
                var result = taken;
                defer result.deinit(allocator, io);
                if (!result.ok) break :scan;
                var inputs: std.ArrayList(maru.session.file_tree.EntryInput) = .empty;
                defer inputs.deinit(allocator);
                for (result.entries.items) |e|
                    inputs.append(allocator, .{ .name = e.name, .kind = e.kind, .identity = e.identity }) catch break :scan;
                dock_tree.applySnapshotWithIdentity(result.path, result.identity, inputs.items) catch break :scan;
                dock_tree.buildRows(allocator, &.{.{ .path = root_path, .active = true }}, &dock_rows) catch break :scan;
                // **아이콘 종류를 채운다** — 안 채우면 모든 행이 `icon_kind = 0`(none)이라 셰브런만
                // 그려진다(실측). 분류는 공유 모듈이 소유한다(macOS 도 같은 함수를 쓴다).
                cell_text.classifyFileTreeRows(dock_rows.items);
                dock_scan_ok = true;
                break;
            }
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }

    var dock_rebuild_failures: usize = 0;
    // **비동기가 진짜인가**의 관측점. **제출한** 프레임과 그 결과가 반영된 프레임이 같으면 아직 그
    // 자리에서 기다리는 것이다. 접기는 제출을 안 하므로 아무 토글이나 재면 판정이 어긋난다.
    var tree_scan_applied: usize = 0;
    var tree_expand_submit_spin: ?usize = null;
    var tree_expand_apply_spin: ?usize = null;
    // **창이 먼저 뜨는가.** 이력 훑기가 끝난 **뒤에** 첫 프레임이 나오면 그것이 예전 동작이다 —
    // 그러면 이 값이 영영 `null` 이다(루프가 받을 것이 남아 있지 않다).
    var agent_apply_spin: ?usize = null;
    // **새로고침이 진짜 다시 훑는가.** 인텐트를 받은 횟수만 세면 속 빈다(라우팅은 이미 다른 판정이
    // 잰다) — **제출**과 그 뒤에 **결과가 또 왔는지**를 갈라 센다.
    var agent_refresh_submits: usize = 0;
    var agent_applies: usize = 0;
    var ag_refresh_judgeable = false;
    var ag_refresh_applies_before: usize = 0;
    var dock_region_uploads: usize = 0;
    var dock_cells_outside: usize = 0;
    var dock_rows_drawn: u16 = 0;
    // ── 도크 스크롤 (W8.7) ──────────────────────────────────────────────────────────────────
    // 콘텐츠가 위로 밀린 양. **그리기(`drawWindow`)와 히트테스트(`rowAtLocalY`)가 같은 값을 본다** —
    // 두 곳에서 따로 세면 부분만 보이는 첫 행에서 그린 행과 눌리는 행이 갈린다.
    var dock_scroll_px: u32 = 0;
    var dock_scroll_shift: u32 = 0;
    var dock_draw_start: usize = 0;
    var dock_tree_top_px: ?f32 = null;
    // 이 프레임의 스크롤바 기하. **그리기와 포인터가 같은 값을 본다** — 따로 재면 보이는 자리와
    // 잡히는 자리가 갈린다(중립 `ScrollbarGeometry` 의 doc 이 그 실패를 적어 뒀다).
    var dock_bar: ?maru.chrome.ui.scroll_area.ScrollbarGeometry = null;
    var sidebar_bar: ?maru.chrome.ui.scroll_area.ScrollbarGeometry = null;
    // 끌고 있는 막대와 **잡은 지점**(누른 y − thumb 위). 그 값을 유지해야 포인터를 따라갈 때 막대가
    // 손가락 밑에서 튀지 않는다(중립 `offsetForPointer` 의 계약).
    const BarDrag = struct { which: enum { dock, sidebar }, grab_dy: f32 };
    var bar_drag: ?BarDrag = null;
    var bar_drag_moves: usize = 0;
    var bar_track_clicks: usize = 0;
    // 판정용 — 끌기 전후의 offset 과 그때 본 막대. **끝 상태에서 읽으면 안 된다**: 그 사이 다른
    // 스크롤이 값을 덮는다(이 세션에서 같은 함정을 세 번 겪었다).
    var sb_bar_seen: ?maru.chrome.ui.scroll_area.ScrollbarGeometry = null;
    var sb_off_before: u32 = 0;
    var sb_off_after: u32 = 0;
    var sb_bar_judgeable = false;
    // **그려졌는가**와 **글자가 침범하는가**. 끌기 판정만으로는 둘 다 안 보인다 — 막대를 안 그려도
    // 기하는 나오고, 거터를 안 비워도 offset 은 잘 움직인다.
    var sb_bar_drawn = false;
    var sb_bar_overlap: usize = 0;
    var sb_track_before: u32 = 0;
    var sb_track_after: u32 = 0;
    var sb_track_judgeable = false;
    // **사이드바 스크롤 판정의 순간**. 아래 스크롤바 시험이 offset 을 0 으로 되돌리는데 그 판정은
    // 끝 상태를 읽는다 — 같은 변수를 덮는 이 함정은 이 포트에서 **네 번째**다(§2m.52·§2m.53·§2m.55).
    var snap_scroll_px: u32 = 0;
    var snap_first_visible: usize = 0;
    var snap_first_band_y: u32 = 0;
    var snap_partial: u32 = 0;
    var snap_active_band_y: ?u32 = null;
    var snap_cards_visible: usize = 0;
    var snap_over_header: usize = 0;
    var snap_content_h: u32 = 0;
    var snap_view_h: u32 = 0;
    var snap_want_band_y: i64 = 0;
    var snap_want_active_y: i64 = 0;
    var snap_active_slot: usize = 0;
    var snap_active_names_view = false;
    var snap_taken = false;
    // **안 넘치면 안 그린다**(중립 계약: *"넘치지 않는 목록에 스크롤바를 그리면 사용자에게 없는
    // 여백을 있다고 말하는 셈"*). 지금 판정은 **있을 때만** 보므로 그 규칙이 깨져도 안 움직인다.
    var fits_bar_quads: usize = 0;
    var fits_judgeable = false;
    // **손을 떼면 따라오기를 멈추는가.** `left_up` 이 드래그를 안 끝내면 그 뒤 모든 마우스 이동이
    // 목록을 굴린다 — 사용자는 "커서를 스쳤을 뿐인데 화면이 뛴다" 로 겪는다.
    var after_release_before: u32 = 0;
    var after_release_after: u32 = 0;
    var after_release_judgeable = false;
    var after_release_dock_before: u32 = 0;
    var after_release_dock_after: u32 = 0;
    // **끝까지 끌면 thumb 이 바닥에 닿는가.** travel 계산이 어긋나면 막대는 멀쩡해 보이는데
    // **마지막 항목에 영영 못 닿는다** — 지금 판정은 thumb 이 트랙 **안**인지만 본다.
    var bottom_gap: f32 = -1;
    // **막대의 상한과 휠의 상한이 같은가.** 둘을 **다른 코드가 따로** 계산한다 — 갈리면 한쪽으로는
    // 갈 수 있는 자리에 다른 쪽으로는 못 간다.
    var bar_max: u32 = 0;
    var wheel_max: u32 = 0;
    var max_judgeable = false;
    var db_seen: ?maru.chrome.ui.scroll_area.ScrollbarGeometry = null;
    var db_off_before: u32 = 0;
    var db_off_after: u32 = 0;
    var db_judgeable = false;
    var dock_scrolls: usize = 0;
    var dock_click_judgeable = false;
    var dock_click_target_row: usize = 0;
    var divider_drag: ?f64 = null;
    var divider_grabs: usize = 0;
    var divider_moves: usize = 0;
    var view_switches: usize = 0;
    var scm_dock_intents: usize = 0;
    var scm_dock_redraws: usize = 0;
    var scm_click_judgeable = false;
    var view_judgeable = false;
    var agent_judgeable = false;
    var agent_view_reached = false;
    var agent_slot_x: u32 = 0;
    var agent_slot_y: u32 = 0;
    var agent_cells: usize = 0;
    var agent_glyph_bytes: usize = 0;
    var agent_ops: usize = 0;
    var agent_cards: usize = 0;
    var agent_groups: usize = 0;
    var agent_titles_drawn: usize = 0;
    // **face 를 못 찾으면 이제 오류다**(`win32_text.faceFor`). 그것이 조용히 늘면 글자가 통째로
    // 빠지는데 셀 수는 quad 가 채워 크게 안 움직인다 — 그래서 따로 센다.
    var agent_raster_err: usize = 0;
    var agent_ops_dropped: usize = 0;
    var dock_digest_before_switch: u64 = 0;
    var dock_cells_before_switch: usize = 0;
    var divider_judgeable = false;
    var dock_w_before_drag: u32 = 0;
    var grid_cols_before_drag: u16 = 0;
    // ── 소스 컨트롤 뷰가 쓸 것들 (W8.7c2) ───────────────────────────────────────────────────
    //
    // **git 은 한 번만 읽는다.** 뷰를 켤 때마다 다시 읽으면 전환이 느려지고, 이 슬라이스의 판정은
    // "뷰가 바뀌면 다른 표면이 그려지는가" 지 "목록이 최신인가" 가 아니다(갱신은 이후 슬라이스).
    var scm_status: []u8 = &.{};
    defer if (scm_status.len != 0) allocator.free(scm_status);
    if (dock_root) |repo| {
        scm_status = readRepoStatus(io, allocator, repo) catch &.{};
    }
    var scm_state = scm_surface.State{};
    var scm_built: ?scm_surface.Built = null;
    defer if (scm_built) |*b| b.deinit();
    // ── 에이전트 세션 도크 (W8.5b⒜) ────────────────────────────────────────────────────────
    // 목록은 아직 비어 있다 — provider 이력을 훑는 데이터 경로는 별개 슬라이스다.
    var agent_state = agent_surface.State{};
    var agent_built: ?agent_surface.Built = null;
    defer if (agent_built) |*b| b.deinit();
    // **목록을 한 번 훑는다**(W8.5b⒝). arena 가 **둘**이다 — 카드가 가리키는 문자열은 프레임보다
    // 오래 살아야 하니 하나는 앱 수명(`agent_arena`)이고, **훑는 동안 나오는 것은 그 자리에서
    // 버린다**(`scan_arena`). 하나로 합치면 파싱 결과가 통째로 남는다: 실측 **44 MB** 를 카드
    // 열한 장의 짧은 문자열 때문에 끝까지 들고 있었다. 백엔드가 64 KiB 스트리밍으로 바꾼 이유가
    // 바로 그 상주 메모리인데(그 함수 doc), 호출자가 arena 하나로 도로 되살리는 꼴이었다.
    // **홈은 한 번만 푼다** — 에이전트 이력 스캔과 상태바의 `~` 축약이 같은 값을 봐야 한다.
    // 두 곳에서 따로 풀면 한쪽만 `HOME` 을 보고 다른 쪽이 `%USERPROFILE%` 를 보는 상태가 생긴다.
    const home_env = maru.os_env.allocValue(allocator, "HOME");
    defer if (home_env) |h| allocator.free(h);
    const up_env = maru.os_env.allocValue(allocator, "USERPROFILE");
    defer if (up_env) |u| allocator.free(u);
    const home_dir = maru.user_paths.homeDirFor(@import("builtin").os.tag, home_env, up_env);
    var agent_arena = std.heap.ArenaAllocator.init(allocator);
    defer agent_arena.deinit();
    // **훑는 동안 나오는 것**도 이제 앱 수명이다 — 결과를 루프가 받으므로 그때까지 살아 있어야 하고,
    // 백엔드 doc 이 요구하는 것도 그것이다("In production `allocator` must be process-lifetime" —
    // `deinit` 이 nonblocking 이라 worker 가 그 뒤에 만질 수 있다). 예전 코드는 이 arena 를 블록
    // 끝에서 버렸는데, **기다렸기 때문에** 무사했던 것이다.
    //
    // **arena 가 아니다.** 이력이 크면 훑기가 이 기계에서 40 MB 를 쓰는데 arena 는 그것을 안 돌려준다
    // — 앱 수명으로 올리는 순간 그 40 MB 가 창에 눌러앉는다.
    var agent_counting = CountingAllocator{ .child = allocator };
    var agent_backend: ?agent_archive_backend.Backend = null;
    defer if (agent_backend) |*b| b.deinit();
    var agent_items: std.ArrayList(maru.chrome.components.session_dock.types.Item) = .empty;
    // 재투영 재료 — 그룹을 접으면 이것으로 목록을 다시 만든다(레코드 원본은 스캔 arena 와 함께 사라진다).
    var agent_archive: AgentArchive = .{};
    var agent_pointer_intents: usize = 0;
    var agent_applied_intents: usize = 0;
    var agent_redraws: usize = 0;
    // **죽은 컨트롤이었는지**의 관측점. 그려진 그룹 헤더를 눌러 목록이 **줄어드는지** 본다 —
    // 인텐트 개수만 세면 속 빈다(적용이 안 돼도 인텐트는 난다).
    var ag_click_judgeable = false;
    var ag_items_before: usize = 0;
    var ag_items_after: usize = 0;
    var ag_collapsed_after: usize = 0;
    var ag_expand_before: ?u64 = null;
    var ag_expand_after: ?u64 = null;
    // **되돌아오는가.** 접기만 재면 `isCollapsed`·제거가 틀려도 초록이다 — 한 번 접히면 그만이니까.
    var ag_items_reopened: usize = 0;
    var ag_collapsed_reopened: usize = 1;
    // **둘을 접고 하나만 편다.** 번호→키 대응이 흔들리면 **엉뚱한 그룹**이 펴진다 — 하나만
    // 재면 그 부류가 통째로 안 보인다(접힌 그룹도 헤더는 남아 번호가 안 밀리는 것이 전제다).
    var ag_multi_judgeable = false;
    var ag_multi_keys_before: usize = 0;
    var ag_multi_keys_after: usize = 0;
    var ag_multi_first_still: bool = false;
    // **어느 카드가 사라졌는가.** 개수만 보면 **엉뚱한 카드를 지워도** 초록이다(늘 마지막 여섯을
    // 지우는 재투영이 그렇다). 접은 그룹에 속한 레코드가 목록에 **하나도 안 남아야** 한다.
    var ag_wrong_cards: usize = 0;
    var ag_kept_cards: usize = 0;
    // **펼친 카드가 든 그룹을 접었다 펴면 그 카드가 그대로여야 한다.** 이것이 `expanded_identity` 가
    // 인덱스가 아니라 identity 인 **이유**다(그 필드 doc: *"목록이 갱신되면 인덱스는 밀리고, 그러면
    // 엉뚱한 카드가 펼쳐진 채로 남는다"*). 지금 판정은 펼침이 **붙는지**만 보고 **살아남는지**는 안 본다.
    var ag_expand_survived: bool = false;
    var ag_expand_target: ?u64 = null;
    // **호버가 도는가.** 클릭만 재면 `.move` 경로가 통째로 죽어 있어도 초록이다 — 사용자는 "카드에
    // 마우스를 올려도 아무 표시가 안 난다" 로 겪는다(§2m.50 이 사이드바에서 겪은 그 부류).
    var ag_hover_judgeable = false;
    var ag_hover_redraws_before: usize = 0;
    var ag_hover_redraws_after: usize = 0;
    var ag_hover_intents_before: usize = 0;
    var ag_hover_intents_after: usize = 0;
    // **정렬이 진짜 뒤집히는가.** 라벨만 바뀌고 목록은 그대로면 사용자는 "눌러도 안 바뀐다" 로
    // 겪는다 — 그래서 **첫 카드의 레코드 번호**를 견준다(뒤집으면 그것이 달라진다).
    var ag_sort_judgeable = false;
    var ag_sort_first_before: u64 = 0;
    var ag_sort_first_after: u64 = 0;
    var ag_sort_order_after: bool = false;
    // **상주 메모리를 판정으로 낸다.** 이 둘이 갈라져 있는 것이 눈에 안 보이는 성질이라, 수치로
    // 내지 않으면 다음 사람이 arena 하나로 되돌려도 아무 판정이 안 움직인다.
    var agent_scan_kb: usize = 0;
    // **훑는 중임을 화면에 말한다**(중립이 이미 문구·해골 줄을 갖고 있다 — `loading`/`refreshing`/
    // `partial`). 예전에는 이 셋을 아무도 안 세워서, 이력이 큰 기계에서 **20 초 동안 빈 목록**이
    // "세션이 없다" 로 보였다.
    var agent_scan_finished = false;
    var agent_scan_partial = false;
    var agent_loading_frames: usize = 0;
    var agent_refreshing_frames: usize = 0;
    var notice_judgeable = false;
    var notice_items_before: usize = 0;
    var notice_items_during: usize = 0;
    var notice_digest_idle: u64 = 0;
    var notice_digest_busy: u64 = 0;
    var notice_settled_judgeable = false;
    var notice_still_busy = false;
    // **이력이 없는 기계는 실패가 아니다.** 카드가 0 인 이유가 "이 기계에 이력이 없다" 인지
    // "훑기가 깨졌다" 인지 갈라 두지 않으면, provider 를 안 쓰는 기계에서 스모크가 **거짓 실패**를
    // 낸다 — 그리고 그 실패를 무시하기 시작하면 진짜 회귀도 같이 묻힌다(§2m.44 의 그 교훈).
    var agent_list_reason: []const u8 = "";
    {
        // **홈은 중립이 정한다**(`user_paths.homeDirFor`) — Windows 는 `HOME` 이 없어 `%USERPROFILE%`
        // 로 간다. 여기서 손으로 고르면 그 규칙이 두 곳이 된다(그 함수 doc 이 왜 이렇게 되는지 적어 뒀다).
        if (home_dir) |home| {
            agent_backend = agent_archive_backend.Backend.init(agent_counting.allocator(), io) catch null;
            if (agent_backend) |*b| {
                agent_list_reason = submitAgentScan(agent_counting.allocator(), b, home);
                // **아직 결과가 없다.** 이 자리에서 기다리지 않으므로 첫 프레임의 목록은 비어 있고,
                // 루프가 받는 순간 채워진다 — 그래서 여기서는 `pending` 이다.
                if (agent_list_reason.len == 0) agent_list_reason = "pending";
            } else agent_list_reason = "backend_init";
        } else agent_list_reason = "no_home";
    }
    const scm_tokens = chromeTokensFor(cfg);
    var agent_opts = agent_surface.Options{
        .font_family = cfg.font.family,
        .font_fallback = cfg.font.fallback,
        .font_size_pt = cfg.font.size,
        .tokens = &scm_tokens,
        .items = agent_items.items,
    };
    const scm_opts = scm_surface.Options{
        .status_text = scm_status,
        .font_family = cfg.font.family,
        .font_fallback = cfg.font.fallback,
        .font_size_pt = cfg.font.size,
        .tokens = &scm_tokens,
    };

    // **크롬 색은 테마에서 온다**(§2m.33 이 적어 둔 부채를 갚는다). macOS 와 같은 함수를 지난다.
    const chrome_tokens = chromeTokensFor(cfg);

    // 도크 자리의 셀. **기하가 바뀔 때만** 다시 만든다 — 정적인 것에 매 프레임 값을 치르지 않는다.
    // 상단 띠(배경 + 캡션 버튼). 호버가 바뀌면 다시 만든다.
    var titlebar_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer titlebar_cells.deinit(allocator);
    // ── 하단 상태표시줄 셀 (W8.9) ───────────────────────────────────────────────────────────
    var status_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer status_cells.deinit(allocator);
    // **항목마다 프레임 하나**(계약 §3). 아틀라스 업로드가 프레임 수명에 묶여 있어 들고 있어야 한다.
    var status_frames: [max_status_bar_items]?maru.renderer.RenderFrame = @splat(null);
    defer for (&status_frames) |*f| if (f.*) |*fr| fr.deinit(allocator);
    var status_dropped: usize = 0;
    var status_placed: usize = 0;
    var status_outside: usize = 0;
    var status_mismatch: usize = 0;
    var status_uploads: usize = 0;
    var status_items_buf: [max_status_bar_items]StatusBarItem = undefined;
    // 경로는 `~` 로 줄여 담는다 — 그 축약이 계약 §4 의 규칙이다(`sidebarCwdPath`).
    var status_cwd_buf: [512]u8 = undefined;
    var caption_hover: ?usize = null;
    var caption_clicks: usize = 0;
    // 캡션 버튼 **동작** 판정(W8.8⒝). `caption_clicks` 만으로는 속 빈다 — 스모크가 그 자리를 아예
    // 안 눌러서 0 이었고, 0 은 "버튼이 죽었다" 와 구별이 안 된다.
    var caption_judgeable = false;
    var caption_max_before = false;
    var caption_max_after = false;
    var caption_max_restored = true;
    // **프레임리스가 실제로 걸렸는가**(W8.8⒝). `WM_NCCALCSIZE` 처리를 통째로 지워도 기존 판정이
    // 하나도 안 움직였다 — 네이티브 캡션이 돌아오고 우리 버튼이 그 아래 그려지는 상태인데도.
    var frameless_covers = false;
    // **띠 히트테스트가 배선돼 있는가.** `hitTestFrame` 호출을 지워도 순수 테스트 5 개와 스모크가
    // 전부 초록이었다(창을 못 끌고 못 늘리는 상태인데). 진짜 wndproc 에 물어본다.
    var nchittest_strip: isize = 0;
    var nchittest_button: isize = 0;
    var nchittest_below: isize = 0;
    // 띠 안, **사이드바 헤더 아이콘 자리**의 판정. `HTCAPTION` 이면 OS 가 드래그로 먹어 아이콘이
    // 안 눌린다 — 그리고 그때 **다른 판정은 하나도 안 움직인다**(합성 클릭은 wndproc 를 안 탄다).
    var nchittest_sidebar_icon: isize = 0;

    var sidebar_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer sidebar_cells.deinit(allocator);
    var sidebar_frame: ?maru.renderer.RenderFrame = null;
    var sidebar_header_frame: ?maru.renderer.RenderFrame = null;
    // 헤더가 차지한 높이 — 히트테스트가 같은 값을 봐야 그린 자리와 눌리는 자리가 안 갈린다.
    var sidebar_header_h: u32 = 0;
    var sidebar_header_icon_band: u32 = 0;
    var sidebar_card_cols: u16 = 0;
    var sidebar_card_columns: ?maru.chrome.components.sidebar.Columns = null;
    var sidebar_header_icon_glyphs: usize = 0;
    var sidebar_header_search_glyphs: usize = 0;
    var sidebar_header_outside: usize = 0;
    var sidebar_card_over_header: usize = 0;
    var sidebar_cells_clipped: usize = 0;
    var sidebar_cards_visible: usize = 0;
    // ── 사이드바 스크롤 (W8.7 짝) ───────────────────────────────────────────────────────────
    // 도크와 같은 모양이다 — **그리기와 히트테스트가 같은 값을 본다.** 헤더는 스크롤 무관 고정이라
    // `slotAt` 이 그 규칙을 소유한다.
    var sidebar_scroll_px: u32 = 0;
    // **행 목록은 힙이다**(옛 `[16]` 배열이 아니다) — 그 상한이 카드 열여섯을 넘는 순간 기하와
    // 그림을 갈라 놓았다(`sidebarRowsFor` doc). 한 벌을 돌려 쓰고, 슬라이스는 다음 호출까지만 산다.
    var sidebar_rows_scratch: std.ArrayList(maru.chrome.components.sidebar.Row) = .empty;
    defer sidebar_rows_scratch.deinit(allocator);
    var sidebar_reveals: usize = 0;
    var sidebar_reveal_request = false;
    var last_active_slot: usize = std.math.maxInt(usize);
    var sidebar_first_visible: usize = 0;
    var sidebar_first_band_y: u32 = 0;
    var sidebar_partial: u32 = 0;
    var sidebar_active_band_y: ?u32 = null;
    var sidebar_scrolls: usize = 0;
    var sidebar_scroll_judgeable = false;
    var a3_card_slot: ?usize = null;
    var a3_header: ?maru.chrome.components.sidebar.HeaderRegion = null;
    var a3_card_clicks: usize = 0;
    var a3_header_clicks: usize = 0;
    var a3_redraws: usize = 0;
    var sidebar_scroll_click_sent = false;
    var sidebar_slot_before_scroll_click: ?usize = null;
    var sidebar_scroll_clicked_slot: ?usize = null;
    // ── 사이드바 입력 상태 (W8.8⒜3) ────────────────────────────────────────────────────────
    // **hover 를 들고 다녀야 그림이 바뀐다.** 안 그러면 눌러도 화면이 그대로라 죽은 컨트롤과
    // 구별이 안 된다 — 이 저장소가 SCM 표면에서 겪은 실패다(§2m.35).
    var sidebar_hover_slot: ?usize = null;
    var sidebar_hover_header: ?maru.chrome.components.sidebar.HeaderRegion = null;
    var sidebar_pointer_events: usize = 0;
    var sidebar_redraws: usize = 0;
    var sidebar_card_clicks: usize = 0;
    var sidebar_header_clicks: usize = 0;
    var sidebar_last_slot: ?usize = null;
    var sidebar_last_header: ?maru.chrome.components.sidebar.HeaderRegion = null;
    var sidebar_judgeable = false;
    var session_spawns: usize = 0;
    var session_spawn_failures: usize = 0;
    var tab_switches: usize = 0;
    var switch_judgeable = false;
    var dock_scroll_judgeable = false;
    var dock_scroll_click_sent = false;
    var dock_row_before_scroll_click: ?usize = null;
    var dock_scroll_clicked_row: ?usize = null;
    var active_before_switch: usize = 0;
    var grid_digest_before_switch: u64 = 0;
    var grid_digest_after_switch: u64 = 0;
    var active_matches_selected = false;
    var background_ink: usize = 0;
    var sidebar_header_drawn: DrawnHeaderIcons = .{};
    defer if (sidebar_frame) |*f| f.deinit(allocator);
    defer if (sidebar_header_frame) |*f| f.deinit(allocator);
    var sidebar_uploads: usize = 0;
    var sidebar_glyphs: usize = 0;
    var sidebar_outside: usize = 0;
    // **카드는 세션 목록에서 나온다.** 하드코딩하면 세션이 늘어도 사이드바가 모른다.
    var sidebar_cards: std.ArrayList(SidebarCard) = .empty;
    defer sidebar_cards.deinit(allocator);
    const folder_name: []const u8 = if (dock_root) |r| std.fs.path.basename(r) else "";
    try refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items);
    // **기하가 바뀔 때마다 다시 짓는다.** 내용(브랜치·cwd)은 이 슬라이스에서 안 바뀌지만 **자리는
    // 바뀐다** — 창을 키우면 바가 아래로 가고 폭이 넓어진다. 시작에 한 번만 지었더니 창이 커진 뒤
    // 옛 자리(실측 y=574, w=984)에 남아 **화면에서 통째로 사라졌다**. 스모크는 자기 창 크기가
    // 안 변해서 그 상태에서도 초록이었다 — 실기 캡처가 잡았다(2026-08-26).
    const status_items = buildStatusBarItems(&status_items_buf, scm_status, dock_root, home_dir, &status_cwd_buf);
    var status_rebuilds: usize = 0;
    rebuildStatusBar(allocator, &status_cells, geom.status_bar, cell_w, cell_h, &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &status_uploads, status_items, &status_frames, &status_dropped, &status_placed, &status_outside, &status_mismatch, &status_rebuilds);
    try rebuildTitlebarCells(allocator, &titlebar_cells, client_w, sidebar_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens);
    try rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused);

    var dock_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer dock_cells.deinit(allocator);
    var dock_tree_frame: ?maru.renderer.RenderFrame = null;
    var view_bar_frame: ?maru.renderer.RenderFrame = null;
    var view_bar_glyph_top: ?f32 = null;
    defer if (view_bar_frame) |*f| f.deinit(allocator);
    defer if (dock_tree_frame) |*f| f.deinit(allocator);
    rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};

    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer cells.deinit(allocator);

    // **색도 config 에서 온다.** 예전에는 이 여섯 값이 리터럴이었다 — config 를 읽어 놓고 폰트만 쓰던
    // 자리와 같은 부류다(§2l 이 폰트에서 그것을 잡았다). `appearance.resolve` 가 `"#1e2430"` 같은
    // 문자열을 `Rgb` 로 풀고 대비·기본값 규칙까지 소유하므로, 여기서 hex 를 다시 파싱하지 않는다.
    //
    // 커서 색은 `cursor.color`/`cursor.text` 가 있으면 그것, 없으면 테마의 `cursor`/`background` 다 —
    // macOS 와 같은 폴백이라 두 플랫폼이 같은 화면을 낸다.
    // OSC 4 팔레트 복사본. 프레임마다 코어에서 채운다(위 doc).
    var palette_copy: [256]?maru.terminal.Rgb = @splat(null);
    var colors = maru.renderer.metal_frame.CellColors{
        .default_fg = appearance.theme.foreground,
        .default_bg = appearance.theme.background,
        // **커서를 켠다.** 기본값 `null`은 "커서를 투영하지 않는다"이고(그 doc: 아틀라스 픽셀을 그대로
        // 검증하는 골든 스모크가 커서 블록에 흔들리지 않게 하려는 것), 터미널 화면에는 커서가 있어야 한다.
        // 켜지 않으면 화면이 그럴듯해 보여도 커서 오버레이 투영 경로가 한 번도 안 돈다.
        .cursor = .{
            .block = appearance.cursor.color orelse appearance.theme.cursor,
            .text = appearance.cursor.text orelse appearance.theme.background,
        },
        .selection_bg = appearance.theme.selection,
        .search_match_bg = appearance.theme.search_match,
        .current_match_bg = appearance.theme.search_match_current,
        .config_palette = &appearance.theme.palette,
    };
    // **지우는 색도 테마 배경이다.** 이 값이 셀 배경과 다르면 창 가장자리(격자에 안 맞는 나머지 픽셀)만
    // 다른 색으로 남아 테두리처럼 보인다 — 리터럴이던 동안은 테마를 바꿔도 그 띠가 안 따라왔다.
    const clear = d3d11_present.clearColorFromArgb(0xFF000000 |
        (@as(u32, appearance.theme.background.r) << 16) |
        (@as(u32, appearance.theme.background.g) << 8) |
        @as(u32, appearance.theme.background.b));

    // **리졸버 조립은 `Parsed` 가 소유한다.** 손으로 세 필드를 옮겨 담으면 바인딩 종류가 늘 때 이 자리만
    // 빠진다 — macOS 도 같은 헬퍼를 쓴다.
    var resolver = loaded.keyBindingResolver();

    // **불변식 확인이지 활성 폴백이 아니다.** 로더가 app·terminal·unbind 를 **같은 dedup 풀**에서 만들어
    // chord 가 구조적으로 충돌하지 않는다(`loader.Parsed.terminal_bindings` doc). 그래서 이 갈래는 지금
    // config 경로로는 안 밟힌다 — 그래도 부르는 이유는 그 불변식이 깨졌을 때 **조용히 이상해지지 않게**
    // 하기 위해서다. 모호한 바인딩을 그대로 쓰면 어떤 키가 어디로 갈지 매번 달라진다.
    // `rejected` 가 0 이 아니면 그 불변식이 깨진 것이고, 보고 줄이 그것을 드러낸다.
    var binding_config_rejected = false;
    resolver.validate() catch |err| {
        try stderr.print("  warning: user keybindings are ambiguous({s}) — falling back to built-ins\n", .{@errorName(err)});
        resolver = .{};
        binding_config_rejected = true;
    };

    var keys_to_shell: usize = 0;
    var bytes_to_shell: usize = 0;
    var app_actions: usize = 0;
    var keys_ignored: usize = 0;
    var preedit_updates: usize = 0;
    var preedit_failures: usize = 0;
    var preedit_max_bytes: usize = 0;
    var paste_out: PasteOutcome = .{};
    // 붙여넣기 보호 설정 — **사용자 config 에서 온다**(W7.5).
    const paste_protection = cfg.input.paste_protection;
    const bracketed_paste_is_safe = cfg.input.bracketed_paste_is_safe;
    var osc52_writes: usize = 0;
    var osc52_reads: usize = 0;
    var osc52_reads_denied_unimplemented: usize = 0;
    // W7.4d 마우스. **갈래별로 센다** — 합치면 "선택이 안 되는데 이벤트는 왔다"를 못 가른다.
    var mouse_events: usize = 0;
    var mouse_reports: usize = 0;
    // **큐에 실제로 들어간 리포트 수.** `mouse_reports` 는 이벤트마다 1 이라 휠 안쪽 루프가 1 번 돌든
    // 10 번 돌든 같은 값이다 — 그것으로는 "눈금당 한 번" 을 지키는지 볼 수 없다.
    var mouse_report_commands: usize = 0;
    // **큐에서 버려진 코어 명령.** `enqueueCoreCommand` 는 큐가 차면 오류를 내는데 그것을 삼키면
    // 선택·스크롤이 조용히 사라지고 원인을 못 찾는다(빠른 드래그에서 실제로 찰 수 있다).
    var core_command_drops: usize = 0;
    var selections: usize = 0;
    // **선택이 화면까지 갔는가.** 코어에 선택이 생기는 것과 그것이 셀에 칠해지는 것은 다른 일이고,
    // 실측으로 그 둘이 갈렸다(`selections` 는 오르는데 파란 띠가 없었다). 프레임 수를 따로 센다.
    var selection_frames: usize = 0;
    var extends: usize = 0;
    var word_selections: usize = 0;
    var line_selections: usize = 0;
    var scrolls: usize = 0;
    var alt_scrolls: usize = 0;
    var copies: usize = 0;
    var copy_bytes: usize = 0;
    var right_click_pastes: usize = 0;
    var right_click_menus_unimplemented: usize = 0;
    var capture_losses: usize = 0;
    var dock_pointer_events: usize = 0;
    var dock_row_clicks: usize = 0;
    var dock_row_toggles: usize = 0;
    var expand_judgeable = false;
    var expand_row: usize = 0;
    var expand_rows_before: usize = 0;
    var expand_rows_after: usize = 0;
    var expand_rows_collapsed: usize = 0;
    var dock_click_answer: ?usize = null;
    var dock_click_name_buf: [64]u8 = undefined;
    var dock_click_name_len: usize = 0;
    var dock_last_row: ?usize = null;
    var selections_before_term_click: usize = 0;
    var dock_clicks_before_term_click: usize = 0;
    // Alt 를 meta 로 쓸지 — **사용자 config 에서 온다**. 기본 `true` 다(Alt+B/F 가 readline 단어 이동).
    const option_as_meta = cfg.input.option_as_meta;
    // 우클릭 동작 — **사용자 config 에서 온다**(W7.5). 기본값은 `paste` 다(PuTTY/X11 식, 사용자 결정).
    const right_click_action: maru.config.theme.RightClick = cfg.input.right_click;
    var dragging = false;
    var last_motion_cell: ?win32_mouse.Cell = null;
    var wheel_acc: win32_mouse.WheelAccumulator = .{};
    // **표면마다 자기 나머지를 갖는다.** 누적기는 `WHEEL_DELTA` 미만을 다음 메시지로 넘기는데(정밀
    // 터치패드), 그것을 나눠 쓰면 **한 표면에서 조금 민 것이 다른 표면에서 한 줄로 튄다.** 축도
    // 같다(가로로 민 것이 세로로 튄다) — 대각선 제스처가 흔한 트랙패드에서 늘 일어난다.
    //
    // 실측으로 이 슬라이스의 시험이 그것에 막혔다: 사이드바에 남은 `+40` 이 도크의 첫 눈금(`-120`)을
    // 먹어 도크가 **안 굴러갔다**(§2m.84).
    var wheel_acc_h: win32_mouse.WheelAccumulator = .{};
    var wheel_acc_sidebar: win32_mouse.WheelAccumulator = .{};
    var wheel_acc_dock: win32_mouse.WheelAccumulator = .{};
    var wheel_acc_editor: win32_mouse.WheelAccumulator = .{};
    var last_ime_caret: ?win32_mouse.Cell = null;
    // 마지막으로 계산한 마우스 셀. **휠 좌표가 화면 기준으로 오는 것을 놓치면 창 위치만큼 어긋나는데**,
    // 카운터만으로는 그것이 안 보인다 — 이 줄이 그 자리를 지킨다.
    var last_mouse_cell: ?win32_mouse.Cell = null;
    // **휠 셀은 따로 센다.** 호버 리포트(트래킹 any)가 매 픽셀 들어와 마지막 값을 덮으므로,
    // 공용 칸으로는 "휠 좌표가 화면 기준이라 어긋났는지" 를 볼 수 없다.
    var last_wheel_cell: ?win32_mouse.Cell = null;
    var ime_caret_updates: usize = 0;
    var click_tracker: win32_mouse.ClickTracker = .{};
    // **사용자 설정을 OS 에 묻는다.** 값을 코드에 박으면 접근성 설정(느린 더블클릭·스크롤 줄 수)을
    // 무시하게 된다. 규칙은 순수 함수가 갖고 이 값들은 그 인자다(§2k, OS-as-parameter).
    const double_click_ms = win32_mouse.systemDoubleClickMs();
    const click_slop_x = win32_mouse.systemDoubleClickSlopX();
    const click_slop_y = win32_mouse.systemDoubleClickSlopY();
    const wheel_lines_per_notch = win32_mouse.systemWheelScrollLines();
    // 단어 구분자 — **사용자 config 에서 온다**(W7.5). 기본값은 빈 값이라 공백만 경계다(비공백 run
    // 전체를 선택한다). 문자열을 arena 에서 빌리므로 `loaded` 가 살아 있어야 한다.
    const default_word_separators: []const u8 = cfg.input.word_separators;
    // OSC 52 읽기 정책 — **사용자 config 에서 온다**(W7.5). 기본값은 `deny` 다(원격 프로그램의 로컬
    // 클립보드 탈취를 막는 사용자 결정 — `config/theme.zig` `Osc52Config`).
    const osc52_read_policy: maru.config.theme.Osc52Read = cfg.osc52.read;
    var clipboard_errors: usize = 0;

    var counts: win32_terminal.FrameCounts = .{};
    var frames: usize = 0;
    var region_uploads: usize = 0;
    var atlas_resizes: usize = 0;
    var last_cells: usize = 0;
    var term_cells_in_dock: usize = 0;
    var term_cells_before_rect: usize = 0;
    var resizes: usize = 0;
    var grid_mismatches: usize = 0;
    var close_requested = false;
    var ended = false;
    // **각본을 보내지 않는다.** 이 스모크는 사람이 타이핑하는 자리다 — fixture 각본은 `exit`으로 끝나서
    // 셸이 죽고, 그 뒤 키는 죽은 PTY 에 쓰인다(실측: keys_to_shell=16 인데 화면에 안 나왔다).
    // 각본으로 끝내는 검증은 `win32-frame-smoke`(W7.2c-1)가 한다.
    // ── 라우팅 판정 (W8.7b) ─────────────────────────────────────────────────────────────────
    //
    // 사람 없이 잰다: **도크에 한 번, 터미널에 한 번** 합성 클릭을 넣고 서로의 카운터가 안 움직이는지
    // 본다. 계약이 적어 둔 두 실패가 여기서 갈린다 — 터미널에 갈 것이 도크로 새면 셸이 먹통이 되고,
    // 반대면 도크가 죽은 컨트롤이 된다.
    var spins: usize = 0;
    // **판정 단계는 스모크에서만 돈다.** 이 루프는 `win32-terminal`(제품)과
    // `win32-terminal-smoke`(판정)가 **같이 쓴다** — 스핀 번호로만 가른 단계들이 제품에서도 돌아,
    // 실기가 세션을 스스로 만들고 셸에 `MARK-ONE` 을 치고 창을 최대화하고 그룹을 접었다(실측
    // 2026-08-26: 캡처에 그 글자가 찍혀 드러났다). 스모크만 스핀 상한을 넘기므로 그것이 판정이다.
    const smoke = max_spins != null;
    var frames_total: usize = 0;
    var settle_frames: usize = 0;
    var agent_settling = false;
    while ((max_spins == null or spins < max_spins.?) and !window.quit_requested and !close_requested) : ({
        // ── 스모크의 단계 번호는 **이력이 온 뒤부터** 센다 ─────────────────────────────────────
        //
        // 단계가 고정된 `spins` 번호에 걸려 있는데 이력 훑기는 이제 **몇백 프레임 뒤**에 온다 —
        // 그냥 두면 카드 판정들이 **빈 목록**을 재고, 기계가 빠르냐 느리냐에 따라 초록·빨강이
        // 오간다(실측으로 275 와 518 을 봤다). 그동안은 번호를 멈춰 세운다.
        //
        // **비동기 판정은 이 번호를 안 쓴다** — `frames_total` 로 잰다. 같은 값을 쓰면 "멈춰 세웠으니
        // 0 이다" 가 되어 판정이 자기 자신을 증명한다.
        frames_total += 1;
        if (agent_settling) settle_frames += 1 else spins += 1;
    }) {
        // ── 훑는 중임을 화면에 말한다 ────────────────────────────────────────────────────
        //
        // **중립이 이미 다 갖고 있다** — `loading` 이면 개수 대신 "분석 중" 을 쓰고 해골 줄을 깔며,
        // `refreshing` 이면 새로고침 아이콘을 죽인다(`session_dock/view.zig`). Windows 는 그 셋을
        // **아무도 안 세우고 있었다**: 이력이 큰 기계에서 20 초 동안 빈 목록이 "세션이 없다" 로 보였다.
        //
        // **프레임 머리에서 한 번 세운다** — 이벤트 처리 중에 도크를 다시 짓는 자리가 여럿이라
        // 각각에 넣으면 한 곳이 빠진다.
        {
            const scanning = agent_backend != null and !agent_scan_finished;
            // `loading` 은 **보여 줄 것이 아직 하나도 없는** 첫 훑기다(중립 doc: 그때 개수만 말하면
            // "0개 표시" 가 되어 세션이 없다는 뜻으로 읽힌다). 목록이 이미 있으면 `refreshing` 이다.
            agent_opts.loading = scanning and agent_items.items.len == 0;
            agent_opts.refreshing = scanning and agent_items.items.len > 0;
            agent_opts.partial = agent_scan_partial;
            if (agent_opts.loading) agent_loading_frames += 1;
            if (agent_opts.refreshing) agent_refreshing_frames += 1;
        }
        if (smoke and spins == 60) {
            // **판정 불가와 실패를 가른다.** 창이 좁아 도크가 없으면 누를 것이 없는데, 그것을
            // `dock_row_clicks=0` 으로만 적으면 고장난 것처럼 읽힌다(이 세션에서 다섯 번째다).
            if (geom.dock.w != 0 and dock_rows_drawn > 2) {
                dock_click_judgeable = true;
                dock_click_target_row = 2;
                const dx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const dy: i32 = @intCast(geom.tree_content.y + cell_h * 2 + cell_h / 2);
                window.postSyntheticMouse(.left_down, dx, dy);
                window.postSyntheticMouse(.left_up, dx, dy);
            }
        }
        // ── 디바이더 드래그 판정 (W8.7c) ────────────────────────────────────────────────────
        //
        // 잡기 띠 한가운데를 누르고 **왼쪽으로 40px** 끈 뒤 뗀다. 도크가 그만큼 넓어져야 하고,
        // 터미널 격자는 그만큼 좁아져야 한다.
        if (smoke and spins == 90 and geom.divider.w != 0) {
            divider_judgeable = true;
            dock_w_before_drag = geom.dock.w;
            grid_cols_before_drag = if (app_window.active()) |a| a.core.size.cols else 0;
            const gx: i32 = @intCast(geom.divider.x + geom.divider.w / 2);
            window.postSyntheticMouse(.left_down, gx, 200);
            window.postSyntheticMouse(.moved, gx - 40, 200);
            window.postSyntheticMouse(.left_up, gx - 40, 200);
        }
        // ── 뷰 전환 판정 (W8.7c2) ──────────────────────────────────────────────────────────
        //
        // 뷰 바의 **두 번째 칸**(소스 컨트롤)을 눌러 도크 그림이 실제로 달라지는지 본다. 개수만
        // 세면 "전환했다" 가 헛일이어도 초록이라, **셀 지문**을 견준다.
        if (smoke and spins == 150 and geom.view_bar.w != 0) {
            const bar = maru.chrome.components.dock_view_bar.Rect{ .x = geom.view_bar.x, .y = geom.view_bar.y, .w = geom.view_bar.w, .h = geom.view_bar.h };
            if (maru.chrome.components.dock_view_bar.slotRect(bar, cell_w, 1)) |r| {
                view_judgeable = true;
                dock_digest_before_switch = d3d11_cells.cellsDigest(dock_cells.items);
                dock_cells_before_switch = dock_cells.items.len;
                const vx: i32 = @intCast(r.x + r.w / 2);
                const vy: i32 = @intCast(r.y + r.h / 2);
                window.postSyntheticMouse(.left_down, vx, vy);
                window.postSyntheticMouse(.left_up, vx, vy);
            }
        }
        // ── 에이전트 도크 판정 (W8.5b⒜) ────────────────────────────────────────────────────
        //
        // **뷰 바 셋째 칸을 눌러 연다.** 그 칸은 지금까지 **빈 도크**를 열었다 — 눌리는데 아무것도
        // 안 그려졌다. 목록이 비어도 헤더·검색 줄·안내는 그려져야 한다: "비었다" 와 "조립이
        // 깨졌다" 는 다른 사실이다.
        if (smoke and spins == 260 and geom.view_bar.w != 0) {
            const bar3 = maru.chrome.components.dock_view_bar.Rect{ .x = geom.view_bar.x, .y = geom.view_bar.y, .w = geom.view_bar.w, .h = geom.view_bar.h };
            if (maru.chrome.components.dock_view_bar.slotRect(bar3, cell_w, 2)) |r3| {
                agent_judgeable = true;
                agent_slot_x = r3.x + r3.w / 2;
                agent_slot_y = r3.y + r3.h / 2;
                const ax: i32 = @intCast(r3.x + r3.w / 2);
                const ay: i32 = @intCast(r3.y + r3.h / 2);
                window.postSyntheticMouse(.left_down, ax, ay);
                window.postSyntheticMouse(.left_up, ax, ay);
            }
        }
        if (smoke and spins == 290 and agent_judgeable) {
            agent_view_reached = dock_view == .agent_sessions;
            if (agent_built) |*b| {
                agent_cells = b.cells.len;
                agent_glyph_bytes = b.text.len;
                agent_ops = b.ops;
                agent_ops_dropped = b.ops_dropped;
                agent_raster_err = b.stats.glyph_raster_error_skip_count;
                // **목록이 글자까지 갔는가.** 셀·바이트 수는 목록이 비어도 0 이 아니다 — 헤더·검색
                // 줄·빈 안내가 그려진다. 그래서 **카드 제목이 그려진 코드포인트 안에 있는지** 본다.
                // 제목은 폭에 맞춰 잘리므로 **앞부분만** 찾는다(잘림은 뒤에서 일어난다).
                for (b.items) |it| switch (it) {
                    .group => agent_groups += 1,
                    .card => |c| {
                        agent_cards += 1;
                        // **8 바이트**다. 카드 제목은 도크 폭에 맞춰 말줄임되는데(실측: ASCII
                        // 제목이 11 글자에서 잘렸다) 앞부분이 그보다 길면 **그려졌는데 못 찾는다**.
                        const needle = codepointPrefix(c.title, 8);
                        if (needle.len >= 3 and std.mem.indexOf(u8, b.text, needle) != null) agent_titles_drawn += 1;
                    },
                };
            }
        }
        // 전환 뒤 **소스 컨트롤 행을 눌러 본다** — 뷰가 바뀌었는데 안 눌리면 죽은 컨트롤이다.
        if (smoke and spins == 200 and dock_view == .source_control) {
            if (scm_built) |*b| {
                const component = maru.chrome.components.scm_dock;
                for (b.items, 0..) |item, i| switch (item) {
                    .file => {
                        const slot = b.frame.tree.find(component.build.NodeIds.item(i)) orelse break;
                        const rect = b.frame.tree.entries[slot].rect;
                        scm_click_judgeable = true;
                        const sx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(rect.x + rect.width / 2)));
                        const sy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(rect.y + rect.height / 2)));
                        window.postSyntheticMouse(.left_down, sx, sy);
                        window.postSyntheticMouse(.left_up, sx, sy);
                        break;
                    },
                    else => {},
                };
            }
        }
        // ── 캡션 버튼 판정 (W8.8⒝) ─────────────────────────────────────────────────────────
        //
        // **버튼을 진짜 누른다.** 최대화(가운데)를 눌러 창 상태가 뒤집히는지 보고, 다시 눌러
        // 되돌린다. 최소화는 창을 숨겨 이후 판정이 못 돌고 닫기는 루프를 끝내므로 **최대화가
        // 유일하게 판정 가능한 버튼**이다. `ShowWindowAsync` 라 상태가 몇 스핀 뒤에 온다.
        if (smoke and spins == 250 and titlebar_px != 0) {
            caption_judgeable = true;
            caption_max_before = window.isMaximized();
            const r = captionButtonRects(client_w, titlebar_px, caption_btn_w)[1];
            const cx: i32 = @intCast(r.x + r.w / 2);
            const cy: i32 = @intCast(r.y + r.h / 2);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
        }
        if (smoke and spins == 330 and caption_judgeable) {
            caption_max_after = window.isMaximized();
            // **지금 폭으로 다시 잰다** — 최대화로 클라이언트가 넓어졌으므로 옛 사각형을 쓰면
            // 화면 한복판을 누르게 된다.
            const r = captionButtonRects(client_w, titlebar_px, caption_btn_w)[1];
            const cx: i32 = @intCast(r.x + r.w / 2);
            const cy: i32 = @intCast(r.y + r.h / 2);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
        }
        if (smoke and spins == 410 and caption_judgeable) caption_max_restored = window.isMaximized();
        // ── 프레임리스 배선 판정 (W8.8⒝) ───────────────────────────────────────────────────
        //
        // 복원이 끝난 뒤 잰다 — 최대화 중에는 창 사각형이 화면 작업영역이라 값이 흔들린다.
        // ── 사이드바 클릭 판정 (W8.8⒜3) ────────────────────────────────────────────────────
        //
        // **카드 한복판과 헤더 아이콘 하나를 실제로 누른다.** 그리고 판정은 내가 보낸 좌표를
        // 되읽지 않는다 — 누른 y 는 **그려진 카드 밴드**에서 나오고, 답은 중립 `slotAt` 이 낸다.
        // ── 도크 스크롤 판정 (W8.7) ────────────────────────────────────────────────────────
        //
        // **굴린 뒤에도 "그린 것 = 눌리는 것" 인가.** 트리 한복판에서 아래로 굴리고, 뷰포트 맨 위
        // 픽셀을 눌러 **그 자리에 실제로 그려진 행**이 나오는지 본다.
        // **넘치는지를 본다, 행 수가 아니라.** 뷰포트가 콘텐츠보다 크면 굴릴 것이 없고, 그때
        // `dock_scrolls=0` 은 고장이 아니라 **정상**이다(첫 판에서 행 수로 가드해 그것을 실패로
        // 읽었다).
        // **탐색기 뷰일 때 굴려야 한다.** spin 150 에 소스 컨트롤로 바뀌므로 그 앞이다 — 처음에
        // 430 에 뒀더니 **보이지도 않는 트리**를 굴리고 클릭은 죽은 경로로 갔다(`clicked_row` 가
        // spin 60 의 옛 값 그대로였다).
        // ── 폴더 펼치기 판정 ───────────────────────────────────────────────────────────────
        //
        // **행 수가 늘었다가 돌아와야 한다.** 개수만 세면 속 빈다 — 누른 것이 파일이어도 클릭은
        // 세어진다. 그래서 **디렉터리 행을 골라** 누르고 목록 길이를 견준다.
        if (smoke and spins == 40 and dock_view == .explorer and geom.tree_content.w != 0) {
            for (dock_rows.items, 0..) |r, i| switch (r) {
                .directory => |dir| {
                    if (dir.expanded) continue;
                    expand_judgeable = true;
                    expand_row = i;
                    expand_rows_before = dock_rows.items.len;
                    const ex: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                    const ey: i32 = @intCast(geom.tree_content.y + cell_h * @as(u32, @intCast(i)) + cell_h / 2);
                    window.postSyntheticMouse(.left_down, ex, ey);
                    window.postSyntheticMouse(.left_up, ex, ey);
                    break;
                },
                else => {},
            };
        }
        if (smoke and spins == 55 and expand_judgeable) expand_rows_after = dock_rows.items.len;
        // ── 도크 스크롤바 판정 (W8.10) ─────────────────────────────────────────────────────
        //
        // **트리를 넘치게 만든다.** 기본 상태에서는 21 행이라 뷰포트에 다 들어가고, 그러면 막대가
        // 아예 안 뜬다(넘치지 않는 목록에 그리는 것은 중립이 금지한다). 사이드바 쪽만 재고 도크는
        // "같은 헬퍼를 쓴다" 로 넘기면 **그 배선이 실제로 도는지는 아무도 안 재는 상태**가 된다.
        //
        // 접힌 디렉터리를 차례로 눌러 행을 늘린다 — 한 번에 하나씩(펼치기가 스캔을 기다린다).
        // **탐색기로 되돌린다** — 그 앞 판정이 뷰를 에이전트로 바꿔 놨고, 도크 막대는 탐색기
        // 뷰에서만 뜬다(SCM·에이전트는 자기 컴포넌트가 스크롤을 소유한다).
        if (smoke and spins == 655) {
            const bar3 = geom.view_bar;
            if (maru.chrome.components.dock_view_bar.slotRect(.{ .x = bar3.x, .y = bar3.y, .w = bar3.w, .h = bar3.h }, cell_w, 0)) |r0| {
                const vx: i32 = @intCast(r0.x + r0.w / 2);
                const vy: i32 = @intCast(r0.y + r0.h / 2);
                window.postSyntheticMouse(.left_down, vx, vy);
                window.postSyntheticMouse(.left_up, vx, vy);
            }
        }
        if (smoke and spins >= 656 and spins <= 690 and dock_view == .explorer and
            dock_rows.items.len *| cell_h <= geom.tree_content.h)
        {
            for (dock_rows.items, 0..) |r, i| switch (r) {
                .directory => |dir| {
                    if (dir.expanded) continue;
                    const ex: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                    const ey: i32 = @intCast(geom.tree_content.y + cell_h * @as(u32, @intCast(i)) + cell_h / 2);
                    window.postSyntheticMouse(.left_down, ex, ey);
                    window.postSyntheticMouse(.left_up, ex, ey);
                    break;
                },
                else => {},
            };
        }
        if (smoke and spins == 700) if (dock_bar) |b| {
            db_seen = b;
            db_judgeable = true;
            db_off_before = dock_scroll_px;
            const gx: i32 = @intFromFloat(b.hit_x + 1);
            const gy: i32 = @intFromFloat(b.thumb_y + b.thumb_h / 2);
            window.postSyntheticMouse(.left_down, gx, gy);
            window.postSyntheticMouse(.moved, gx, gy + @as(i32, @intFromFloat(b.track_h / 3)));
            window.postSyntheticMouse(.left_up, gx, gy + @as(i32, @intFromFloat(b.track_h / 3)));
        };
        if (smoke and spins == 705) db_off_after = dock_scroll_px;
        // **행 클릭 판정의 답을 먼저 챙긴다** — 아래 접기 클릭이 같은 변수를 덮는다(도크 스크롤과
        // 사이드바에서 같은 일을 두 번 겪었다).
        if (smoke and spins == 65) {
            dock_click_answer = dock_last_row;
            // **이름도 그때 것을 챙긴다.** 끝 상태에서 읽으면 그 사이 펼치기·접기로 목록이 바뀌어
            // **누른 적 없는 줄의 이름**을 적게 된다(대조하라고 넣은 값이 대조를 방해한다).
            if (dock_last_row) |r| if (r < dock_rows.items.len) {
                const nm: []const u8 = switch (dock_rows.items[r]) {
                    .root => |x| x.label,
                    .directory => |x| x.label,
                    .file, .recent_file => |x| x.label,
                    .recent_header => "<recent-header>",
                    .empty => "<empty>",
                };
                const n2 = @min(nm.len, dock_click_name_buf.len);
                @memcpy(dock_click_name_buf[0..n2], nm[0..n2]);
                dock_click_name_len = n2;
            };
        }
        if (smoke and spins == 70 and expand_judgeable) {
            // 같은 줄을 다시 눌러 **접힌다**. 펼친 뒤 그 줄은 자리가 그대로다(그 위 행이 안 늘었다).
            const ex: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
            const ey: i32 = @intCast(geom.tree_content.y + cell_h * @as(u32, @intCast(expand_row)) + cell_h / 2);
            window.postSyntheticMouse(.left_down, ex, ey);
            window.postSyntheticMouse(.left_up, ex, ey);
        }
        if (smoke and spins == 85 and expand_judgeable) expand_rows_collapsed = dock_rows.items.len;
        if (smoke and spins == 100 and dock_view == .explorer and geom.tree_content.w != 0 and
            dock_rows.items.len *| cell_h > geom.tree_content.h)
        {
            dock_scroll_judgeable = true;
            const wx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
            const wy: i32 = @intCast(geom.tree_content.y + geom.tree_content.h / 2);
            window.postSyntheticMouseWheel(.wheel, wx, wy, -3); // 아래로 세 눈금
        }
        // **굴린 뒤 뷰포트 맨 위를 진짜로 누른다.** 판정이 `rowAtLocalY` 를 직접 다시 부르면
        // **배선이 아니라 재구현**을 재는 꼴이라, 히트테스트에서 스크롤을 빼는 뮤턴트가 그대로
        // 통과했다(실측). 이제 답은 그 호출부가 낸다.
        // **두 판정이 각자 자기 클릭을 읽어야 한다.** 이 클릭이 `dock_last_row` 를 덮으면 앞선
        // 행 클릭 판정(`want_row=2`)이 엉뚱한 값을 보고 실패한다 — 실측으로 그렇게 됐다.
        if (smoke and spins == 115 and dock_scroll_judgeable) {
            dock_row_before_scroll_click = dock_last_row;
            const cx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
            const cy: i32 = @intCast(geom.tree_content.y + 1);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
            dock_scroll_click_sent = true;
        }
        if (smoke and spins == 130 and dock_scroll_click_sent) {
            dock_scroll_clicked_row = dock_last_row;
            dock_last_row = dock_row_before_scroll_click; // 앞선 판정에 그 클릭의 답을 돌려준다
        }
        if (smoke and spins == 470 and sidebar_w != 0 and sidebar_header_h != 0) {
            sidebar_judgeable = true;
            const m_sb = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const card_top = geom.sidebar.y + sidebar_header_h + m_sb.content_pad_v;
            const card_mid: i32 = @intCast(card_top + maru.chrome.components.sidebar.cardHeight(sidebar_cards.items[0].lines, m_sb) / 2);
            const cx: i32 = @intCast(sidebar_w / 2);
            window.postSyntheticMouse(.moved, cx, card_mid);
            window.postSyntheticMouse(.left_down, cx, card_mid);
            window.postSyntheticMouse(.left_up, cx, card_mid);
        }
        if (smoke and spins == 490) {
            maru.app.host.sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = "MARK-ONE" }) catch {};
        }
        // **⒜3 판정은 자기 순간의 답을 챙긴다.** 끝 상태를 읽으면 뒤에 오는 스크롤 시험의
        // 클릭들(＋ 여러 번·카드 두 번)이 그 값을 덮어 엉뚱하게 실패한다.
        if (smoke and spins == 480) a3_card_slot = sidebar_last_slot;
        if (smoke and spins == 510) {
            a3_header = sidebar_last_header;
            a3_card_clicks = sidebar_card_clicks;
            a3_header_clicks = sidebar_header_clicks;
            a3_redraws = sidebar_redraws;
        }
        if (smoke and spins == 500 and sidebar_w != 0 and sidebar_header_h != 0) {
            // 헤더의 **새 워크스페이스(＋)** 칸 — 오른쪽 끝이라 다른 칸과 안 겹친다.
            //
            // **먼저 첫 세션에 표시를 남긴다.** 두 셸이 같은 크기·같은 프롬프트면 화면이 **똑같아서**
            // "지금 어느 세션을 보고 있나" 를 지문으로 못 가른다. 앞선 판에서 그것이 참으로 나온 것은
            // 두 세션의 **격자 크기가 달랐기 때문**이었다 — 즉 그 증거는 버그에 기대고 있었다.
            // 개행을 안 보내므로 아무것도 실행되지 않는다(스모크가 각본을 안 보내는 규칙 그대로).
            const hcols: u32 = sidebar_w / cell_w;
            const col = maru.chrome.components.sidebar.headerIconCol(.new_workspace, hcols);
            const hx: i32 = @intCast(col *| cell_w + cell_w / 2);
            const hy: i32 = @intCast(geom.sidebar.y + sidebar_header_icon_band / 2);
            window.postSyntheticMouse(.moved, hx, hy);
            window.postSyntheticMouse(.left_down, hx, hy);
            window.postSyntheticMouse(.left_up, hx, hy);
        }
        // ── 세션 전환 판정 (W8.8⒞) ─────────────────────────────────────────────────────────
        //
        // 위 `spins == 500` 이 ＋ 를 눌러 세션을 하나 만들고 **그것을 활성**으로 만들었다.
        // 이제 **첫 카드**를 눌러 되돌아가는지 본다. 판정은 활성 탭 번호만 보지 않는다 —
        // 그것은 내가 부른 `selectTab` 을 되읽는 동어반복이다. **터미널 격자의 지문**을 견준다.
        // ── 사이드바 스크롤 판정 (W8.7 짝) ─────────────────────────────────────────────────
        //
        // **넘치게 만든 뒤 굴린다.** ＋ 를 여러 번 눌러 카드가 창 높이를 넘게 한 다음, 목록 위에서
        // 굴리고 **목록 맨 위를 진짜로 눌러** 그 자리에 그려진 카드가 나오는지 본다.
        if (smoke and spins > 570 and spins < 582 and sidebar_header_h != 0 and sessions.items.len < max_win_sessions) {
            const hc: u32 = sidebar_w / cell_w;
            const cpx = maru.chrome.components.sidebar.headerIconCol(.new_workspace, hc);
            const hx: i32 = @intCast(cpx *| cell_w + cell_w / 2);
            const hy: i32 = @intCast(geom.sidebar.y + sidebar_header_icon_band / 2);
            window.postSyntheticMouse(.moved, hx, hy);
            window.postSyntheticMouse(.left_down, hx, hy);
            window.postSyntheticMouse(.left_up, hx, hy);
        }
        // **안 넘칠 때 막대가 없는지**를 그 순간에 센다. 트리는 아직 21 행이라 뷰포트에 들어간다.
        if (smoke and spins == 100 and dock_view == .explorer and geom.tree_content.w != 0 and
            dock_rows.items.len *| cell_h <= geom.tree_content.h)
        {
            fits_judgeable = true;
            const m = scrollbarMetrics();
            const gx: f32 = @floatFromInt(geom.tree_content.x + geom.tree_content.w -| m.gutterPx());
            for (cells.items) |c| {
                // 막대 굵기의 **단색** 쿼드가 거터 자리에 있으면 그린 것이다(음수 UV = 단색).
                if (c.uv[0] < 0 and @abs(c.rect[2] - @as(f32, @floatFromInt(m.width_px))) < 0.5 and
                    c.rect[0] >= gx - 0.5 and c.rect[3] > @as(f32, @floatFromInt(cell_h))) fits_bar_quads += 1;
            }
        }
        // **손을 뗀 **직후** 커서를 옮긴다** — 드래그가 안 끝났으면 그 이동이 목록을 굴린다.
        //
        // **끌기 바로 뒤여야 한다.** 한참 뒤에 두었더니 그 사이 도크 끌기가 있어, 남아 있던 것은
        // 도크 드래그인데 판정은 사이드바만 봤다 — `left_up` 을 지우는 뮤턴트가 **그대로 통과했다**
        // (실측 2026-08-26). 그리고 **두 offset 을 함께 본다**: 어느 쪽이 새도 잡힌다.
        if (smoke and spins == 645) if (sidebar_bar) |b| {
            after_release_judgeable = true;
            after_release_before = sidebar_scroll_px;
            after_release_dock_before = dock_scroll_px;
            const gx: i32 = @intFromFloat(b.hit_x + 1);
            // **트랙 위쪽으로** 옮긴다 — 지금 offset 이 최대라 아래로는 clamp 되어 안 움직인다.
            window.postSyntheticMouse(.moved, gx, @intFromFloat(b.track_y + 4));
        };
        // ── 에이전트 카드·그룹 클릭 판정 (W8.11) ───────────────────────────────────────
        //
        // **그룹 헤더를 누르면 목록이 줄어야 한다**(그 그룹의 카드가 빠진다). 그리고 카드를 누르면
        // 펼침 identity 가 붙어야 한다. 둘 다 **그린 자리**에서 누른다 — published tree 가 준 자리다.
        if (smoke and spins == 712 and agent_built != null) {
            // 에이전트 뷰로 되돌린다(앞 판정들이 탐색기로 바꿔 놨다).
            const bar4 = geom.view_bar;
            if (maru.chrome.components.dock_view_bar.slotRect(.{ .x = bar4.x, .y = bar4.y, .w = bar4.w, .h = bar4.h }, cell_w, 2)) |r2| {
                const vx: i32 = @intCast(r2.x + r2.w / 2);
                const vy: i32 = @intCast(r2.y + r2.h / 2);
                window.postSyntheticMouse(.left_down, vx, vy);
                window.postSyntheticMouse(.left_up, vx, vy);
            }
        }
        // **기준을 카드 클릭 앞에서 잡는다** — 뒤에서 읽으면 이미 펼쳐진 값이라 `0->0` 으로 보인다.
        // **먼저 도크를 넓힌다.** 정렬 토글은 헤더가 좁으면 컴포넌트가 **일부러 안 낸다**(경계
        // viewport 320, 스모크 기본 도크는 220) — 그 상태로 재면 "안 눌린다" 가 아니라 "없다" 이고,
        // 그 둘을 섞으면 죽은 컨트롤을 정상으로 읽는다.
        if (smoke and spins == 750 and geom.divider.w != 0) {
            const dx: i32 = @intCast(geom.divider.x + geom.divider.w / 2);
            window.postSyntheticMouse(.left_down, dx, 200);
            window.postSyntheticMouse(.moved, dx - 160, 200);
            window.postSyntheticMouse(.left_up, dx - 160, 200);
        }
        // **정렬 토글을 누른다.** 자리는 published tree 가 준다.
        if (smoke and spins == 752) if (agent_built) |*b| {
            if (agentFirstCardIdentity(agent_items.items)) |first| {
                const id = maru.chrome.components.session_dock.build.NodeIds.sort_toggle;
                for (b.frame.tree.entries) |e| {
                    if (e.id != id) continue;
                    ag_sort_judgeable = true;
                    ag_sort_first_before = first;
                    const sx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(e.rect.x + e.rect.width / 2)));
                    const sy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(e.rect.y + e.rect.height / 2)));
                    window.postSyntheticMouse(.left_down, sx, sy);
                    window.postSyntheticMouse(.left_up, sx, sy);
                    break;
                }
            }
        };
        if (smoke and spins == 756) {
            if (agentFirstCardIdentity(agent_items.items)) |f| ag_sort_first_after = f;
            ag_sort_order_after = agent_archive.sort == .oldest_first;
        }
        // **탐색기로 되돌린다.** 앞선 단계들이 도크를 에이전트 뷰로 바꿔 놓아, 그대로 두면 파일
        // 줄이 화면에 없어 이 판정이 영영 `unjudgeable` 이다(실측으로 그렇게 한 번 비었다).
        if (smoke and spins == 768 and geom.view_bar.w != 0) {
            const bar0 = maru.chrome.components.dock_view_bar.Rect{ .x = geom.view_bar.x, .y = geom.view_bar.y, .w = geom.view_bar.w, .h = geom.view_bar.h };
            if (maru.chrome.components.dock_view_bar.slotRect(bar0, cell_w, 0)) |r0| {
                const ex: i32 = @intCast(r0.x + r0.w / 2);
                const ey: i32 = @intCast(r0.y + r0.h / 2);
                window.postSyntheticMouse(.left_down, ex, ey);
                window.postSyntheticMouse(.left_up, ex, ey);
            }
        }
        // ── 파일을 누르면 열린다 (W8.13) ────────────────────────────────────────────────
        //
        // **`.zig` 줄을 골라 누른다.** 아무 행이나 누르면 그것이 폴더일 수도 `.md` 일 수도 있어,
        // "안 열렸다" 가 회귀인지 계약인지 갈리지 않는다. 자리는 그린 행 표가 준다.
        if (smoke and spins == 772) if (dock_view == .explorer) {
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .file) continue;
                if (!std.mem.endsWith(u8, r.file.path, ".zig")) continue;
                // **클릭 경로와 같은 축으로 센다**(`rowAtLocalY` 의 역산) — 다른 산수를 쓰면
                // 판정이 겨눈 줄과 실제로 눌리는 줄이 갈린다.
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const fy: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                open_judgeable = true;
                open_target_len = @min(r.file.path.len, open_target_buf.len);
                @memcpy(open_target_buf[0..open_target_len], r.file.path[0..open_target_len]);
                // **그려진 셀의 지문을 잰다.** 카드 수(모델)는 맞는데 화면은 그대로인 실패를 실측
                // 캡처가 찾았다 — 모델만 보는 판정은 그것을 영영 못 본다.
                //
                // **개수가 아니라 지문이다.** 이 스모크는 그때 세션이 13 개라 새 카드가 **화면 밖**
                // 이고, 개수로 재면 늘기는커녕 줄어든다(실측 124→121). 여기서 물을 수 있는 참인
                // 질문은 "파일을 열면 사이드바가 **다시 그려지는가**" 다 — 안 그리던 것이 그 결함이었다.
                open_sidebar_digest_before = d3d11_cells.cellsDigest(sidebar_cells.items);
                const fx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                window.postSyntheticMouse(.left_down, fx, fy);
                window.postSyntheticMouse(.left_up, fx, fy);
                break;
            }
        };
        // **같은 줄을 다시 누른다** — 창당 경로 유일성(카드가 둘이 되면 안 된다).
        if (smoke and spins == 778) if (open_judgeable) {
            open_files_after_first = open_files.items.len;
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .file) continue;
                if (!std.mem.eql(u8, r.file.path, open_target_buf[0..open_target_len])) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const fy: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                const fx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                window.postSyntheticMouse(.left_down, fx, fy);
                window.postSyntheticMouse(.left_up, fx, fy);
                break;
            }
        };
        // **`.md` 를 누른다 — 열리면 안 된다.** 계약상 마크다운 본문은 WebView 이고 Windows 는
        // WebView2(W8.6)가 아직 없다. 이 판정이 없으면 "나머지는 전부 텍스트로 연다" 쪽으로 규칙을
        // 넓히는 변경이 아무것도 안 깨뜨리며 지나간다 — 사용자는 렌더된 문서 대신 소스를 본다.
        if (smoke and spins == 784) if (dock_view == .explorer) {
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .file) continue;
                if (!std.mem.endsWith(u8, r.file.path, ".md")) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                md_judgeable = true;
                md_files_before = open_files.items.len;
                md_rejects_before = file_rejects;
                const mx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const my: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, mx, my);
                window.postSyntheticMouse(.left_up, mx, my);
                break;
            }
        };
        // **누른 직후에 읽는다.** 뒤로 미루면 그 사이 다른 단계가 연 파일까지 세어 "`.md` 가
        // 열렸다" 고 읽는다 — 실측으로 `files 1->2 md_not_opened=false` 였다. 이 슬라이스에서만
        // **세 번째**로 밟은 자리다(판정은 자기 순간을 챙긴다).
        if (smoke and spins == 785) {
            md_files_after = open_files.items.len;
            md_rejects_after = file_rejects;
            md_reason = last_reject;
        }
        // **곧바로 잰다.** 뒤로 미루면 그 사이의 호버·두 번째 클릭이 지문을 바꿔, 이 판정이
        // "무언가가 사이드바를 건드렸다" 로 흐려진다.
        // ── 편집기를 굴린다 ────────────────────────────────────────────────────────────
        //
        // **그린 셀의 지문을 견준다.** `first_line` 이 움직인 것만 보면 내가 넣은 값을 되읽는
        // 동어반복이다 — 화면이 실제로 그 줄들을 그렸는지가 물어야 할 것이다.
        if (smoke and spins == 790) if (active_view == .file) {
            scroll_judgeable = true;
            scroll_first_before = open_files.items[active_view.file].first_line;
            scroll_digest_before = editor_last_digest;
            const wx: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const wy: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            window.postSyntheticMouseWheel(.wheel, wx, wy, -3);
        };
        // **792 로 당겼다**(예전엔 794). 휠은 **던진 그 스핀에** 적용되므로 네 스핀을 끌 이유가
        // 없고, 끌면 그 사이에 낀 가로 스크롤 판정의 이동까지 이 지문 차이에 섞인다 — 세로가 죽어도
        // 가로 덕에 초록이 된다.
        if (smoke and spins == 792) if (active_view == .file) {
            scroll_first_after = open_files.items[active_view.file].first_line;
            scroll_digest_after = editor_last_digest;
        };
        // **자기 순간을 챙긴다.** 예전에는 이 둘을 맨 뒤(796)에서 읽었는데 그 사이 790 의 스크롤이
        // 화면을 바꿔 놓는다 — "연 직후에 그렸나" 를 묻는 값이 "굴린 뒤에 그렸나" 를 답하고 있었다.
        if (smoke and spins == 775) {
            open_sidebar_digest_after = d3d11_cells.cellsDigest(sidebar_cells.items);
            open_editor_cells = editor_last_cells;
            open_editor_rows = editor_last_rows;
            open_showing_file = active_view == .file;
        }
        // **재개장 직후에 읽는다.** 이 값이 묻는 것은 "다시 눌러도 카드가 안 늘었나" 이고, 뒤로
        // 미루면 그 사이 다른 단계가 연 파일까지 세어 판정이 남의 순간을 본다(실측 `files 1->2`).
        if (smoke and spins == 782) {
            open_files_after_second = open_files.items.len;
        }
        // ── 파일을 보는 중에 글자를 치면 (적대적 검증 2회차) ──────────────────────────
        //
        // **개행은 안 보낸다**(§2m.64 의 규율) — 실행되면 안 된다. 눈에 띄는 글자 하나면 충분하다.
        if (smoke and spins == 798 and active_view == .file) {
            keytest_judgeable = true;
            window.postSyntheticChar('Z');
            // 문서 한가운데를 **끌어** 본다 — 터미널이라면 선택이 생기는 동작이다.
            mousetest_judgeable = true;
            const dx0: i32 = @intCast(geom.terminal.x + geom.terminal.w / 4);
            const dy0: i32 = @intCast(geom.terminal.y + geom.terminal.h / 4);
            const dx1: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const dy1: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            if (app_window.active()) |a| {
                a.lockCore(io);
                mouse_sel_before = a.core.selectionViewportSpan() != null;
                a.unlockCore(io);
            }
            window.postSyntheticMouse(.left_down, dx0, dy0);
            window.postSyntheticMouse(.moved, dx1, dy1);
            window.postSyntheticMouse(.left_up, dx1, dy1);
        }
        // ── 세션 카드의 ✕ (W8.16) ──────────────────────────────────────────────────────
        //
        // **첫 카드가 아니라 둘째를 닫는다** — 첫 것을 닫으면 `pump` 재바인딩이 안 돼도 지나갈 수
        // 있는데, 둘째를 닫으면 그 결함이 안 잡힌다. 그래서 **첫 것을** 닫아 pump 까지 민다.
        // **먼저 맨 위로 되돌린다** — 앞선 단계가 사이드바를 바닥까지 굴려 놨다(§2m.74).
        if (smoke and spins == 861 and geom.sidebar.w != 0) {
            const ux: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const uy: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            var u: usize = 0;
            while (u < 12) : (u += 1) window.postSyntheticMouseWheel(.wheel, ux, uy, 3);
        }
        // **프롬프트 마크를 먹인다.** 이 기계의 셸은 OSC 133 을 안 내므로 `semantic_state` 가 늘
        // `unknown` 이고, 중립 술어는 그것을 **보수적으로 "실행 중"** 으로 본다(그 함수 doc). 통합된
        // 셸이 idle 에서 내는 바로 그 바이트를 넣어, 닫기의 **성공 갈래**도 실제로 밟는다.
        // **가운데 세션을 보게 만든다.** 활성이 마지막이면 색인이 밀려도 clamp 가 우연히 같은 것을
        // 가리켜 판정이 통과한다 — 실측으로 그렇게 한 번 초록이었다.
        if (smoke and spins == 863 and sessions.items.len >= 6) {
            const rr5 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm5 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const top5 = maru.chrome.components.sidebar.rowTop(rr5, 4, sidebar_header_h, mm5, sidebar_scroll_px);
            const cy5: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top5) + @as(i64, @intCast(cell_h / 2)));
            const cx5: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 3);
            window.postSyntheticMouse(.moved, cx5, cy5);
            window.postSyntheticMouse(.left_down, cx5, cy5);
            window.postSyntheticMouse(.left_up, cx5, cy5);
        }
        if (smoke and spins == 865 and sessions.items.len >= 2) {
            const s0 = sessions.items[0];
            s0.surface.lockCore(io);
            s0.surface.core.write("\x1b]133;A\x1b\\") catch {};
            s0.surface.core.write("\x1b]133;B\x1b\\") catch {};
            s0.surface.unlockCore(io);
        }
        if (smoke and spins == 866 and sidebar_card_columns != null and sessions.items.len >= 2) {
            sclose_judgeable = true;
            sclose_sessions_before = sessions.items.len;
            sclose_tabs_before = app_window.tabs.len;
            sclose_second_name_len = @min(sessions.items[1].label().len, sclose_second_name.len);
            // 닫기 **전에** 보고 있던 세션의 이름을 챙긴다(닫은 뒤에 읽으면 이미 바뀐 것을 읽는다).
            sclose_active_want_len = @min(sessions.items[app_window.active_tab].label().len, sclose_active_want.len);
            @memcpy(sclose_active_want[0..sclose_active_want_len], sessions.items[app_window.active_tab].label()[0..sclose_active_want_len]);
            @memcpy(sclose_second_name[0..sclose_second_name_len], sessions.items[1].label()[0..sclose_second_name_len]);
            const rr4 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm4 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const top4 = maru.chrome.components.sidebar.rowTop(rr4, 0, sidebar_header_h, mm4, sidebar_scroll_px);
            const cy4: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top4) + @as(i64, @intCast(cell_h / 2)));
            const rng4 = sidebar_card_columns.?.closeXRange(cell_w);
            const cx4: i32 = @intCast(@as(i64, @intFromFloat(rng4.start)) + @as(i64, @intCast(cell_w / 2)));
            window.postSyntheticMouse(.moved, cx4, cy4);
            window.postSyntheticMouse(.left_down, cx4, cy4);
            window.postSyntheticMouse(.left_up, cx4, cy4);
        }
        // **닫은 뒤에 새로 만들면 id 가 겹치나** — 그 자리 주석이 "겹치면 안 된다" 고 못 박는다.
        // ── 긴 줄을 가로로 굴린다 (W8.17c) ─────────────────────────────────────────────
        //
        // **막대가 서는지와 실제로 움직이는지를 함께 본다** — 막대만 서고 안 움직이면 죽은 컨트롤이고,
        // 움직이기만 하고 막대가 없으면 얼마나 남았는지 알 길이 없다.
        // **자기 순간을 챙긴다** — 앞뒤가 전부 남의 순간이다. 786 에는 곧 **두 번째 파일**이 열려
        // 뒤에서 읽으면 다른 문서를 재고, 795 의 구분선 드래그는 터미널 폭을 바꿔 지문을 통째로
        // 흔들며, 799 는 `first_line` 을, 802 는 활성 뷰를 바꾼다. 세로 판정을 792 로 당겨 비운
        // **793~795** 가 이 판정의 창이다.
        if (smoke and spins == 793 and active_view == .file) {
            hscroll_judgeable = true;
            hscroll_col_before = open_files.items[active_view.file].first_col;
            hscroll_max_cols = open_files.items[active_view.file].max_cols;
            hscroll_digest_before = editor_last_digest;
            hbar_before = editor_last_hbar;
            const hx: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const hy: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            // **가로 휠로 찌른다** — Shift+휠은 `GetKeyState` 로 모디파이어를 읽어(창의 규약)
            // 합성 메시지에 실을 길이 없다. `wheel_h` 는 그 실물 경로를 그대로 밟는다.
            window.postSyntheticMouseWheel(.wheel_h, hx, hy, 3);
        }
        if (smoke and spins == 794 and hscroll_judgeable and active_view == .file) {
            hscroll_col_after = open_files.items[active_view.file].first_col;
            hscroll_digest_after = editor_last_digest;
            hbar_after = editor_last_hbar;
            // ── 끝은 끝이다 ───────────────────────────────────────────────────────────
            //
            // **상한이 없으면 화면이 빈다.** 오른쪽으로 계속 굴리면 `first_col` 이 문서 폭을 지나
            // 아무 글자도 없는 자리를 보게 되는데, 그때도 "굴러가긴 했다" 는 판정은 초록이다.
            // 그래서 **끝까지 굴려** 두 가지를 본다: 폭을 안 지났는가, 그리고 중립이 세운 thumb 이
            // **트랙 오른쪽 끝에 닿았는가**.
            const bx: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const by: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            var bi: usize = 0;
            while (bi < 12) : (bi += 1) window.postSyntheticMouseWheel(.wheel_h, bx, by, 3);
        }
        if (smoke and spins == 795 and hscroll_judgeable and active_view == .file) {
            hend_col = open_files.items[active_view.file].first_col;
            hend_max_cols = open_files.items[active_view.file].max_cols;
            hend_hbar = editor_last_hbar;
            hend_hmax_before = open_files.items[active_view.file].hmax_col;
        }
        // ── 범위를 넘긴 열은 다음 프레임에 되돌아온다 ─────────────────────────────────
        //
        // 세로가 이미 겪은 실패(`first=1000000` 에서 **빈 문서**)의 가로 짝이다. 창이 넓어지면 갈 수
        // 있는 오른쪽 끝이 줄어드는데, 휠이 올 때만 상한을 잡으면 그때까지 문서 오른쪽에 **빈
        // 자리**가 남는다. 구분선 드래그(795)로는 이 방향을 못 만든다 — 그것은 터미널을 **좁혀**
        // 상한을 늘린다. 그래서 세로가 쓰는 방식 그대로 **직접 넘긴 값을 넣어** 되돌아오는지 본다.
        if (smoke and spins == 796 and hscroll_judgeable and active_view == .file) {
            hoob_judgeable = true;
            open_files.items[active_view.file].first_col = 10_000;
        }
        if (smoke and spins == 798 and hoob_judgeable and active_view == .file) {
            hoob_col_after = open_files.items[active_view.file].first_col;
            hoob_hmax = open_files.items[active_view.file].hmax_col;
            hoob_cells = editor_last_cells;
        }
        // ── 터미널 위의 가로 휠은 아무 일도 안 해야 한다 (W8.17c 적대적 검증) ────────────
        //
        // **여기는 `unreachable` 이 있는 길이다.** 리포트 변환의 switch 가 가로 휠을 "위에서 이미
        // 버렸다" 고 전제하는데, 그 버리는 줄이 사라지면 안전 빌드에서 **패닉**이다. 컴파일러는
        // 그것을 안 잡아 준다(분기가 존재하기만 하면 된다).
        // **리포팅을 켜고 던진다.** 끈 채로는 리포트 변환에 **닿지도 않아서**(`reportsToShell` 이
        // false 라 그 앞에서 나간다) 버리는 줄을 지워도 아무 일이 안 난다 — 실측으로 그 뮤턴트가
        // 살아남았다. TUI 가 마우스를 잡은 상태가 이 길의 실제 조건이라 그것을 만들어 준다.
        if (smoke and spins == 820 and active_view == .terminal) if (app_window.active()) |a| {
            hterm_judgeable = true;
            hterm_scrolls_before = scrolls + alt_scrolls;
            hterm_reports_before = mouse_report_commands;
            a.lockCore(io);
            a.core.mouse_tracking = .any;
            a.unlockCore(io);
            const tx: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const ty: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            window.postSyntheticMouseWheel(.wheel_h, tx, ty, 3);
            window.postSyntheticMouseWheel(.wheel_h, tx, ty, -3);
        };
        // **되돌린다** — 뒤의 `core_modes` 판정이 이 값을 읽는다(시험은 자기가 바꾼 것을 되돌린다).
        if (smoke and spins == 822 and hterm_judgeable) if (app_window.active()) |a| {
            a.lockCore(io);
            a.core.mouse_tracking = .none;
            a.unlockCore(io);
        };
        if (smoke and spins == 823 and hterm_judgeable) {
            hterm_scrolls_after = scrolls + alt_scrolls;
            hterm_reports_after = mouse_report_commands;
        }
        // ── 막대를 끈다 (W8.17c) ───────────────────────────────────────────────────────
        //
        // **일정의 꼬리에서 한다.** 793~798 은 이미 휠 판정이 쓰고, 802 뒤로는 화면이 터미널이다.
        // 그래서 여기서 ⑴ 탐색기로 되돌리고 ⑵ 그 파일을 다시 열고 ⑶ 막대를 끈다.
        if (smoke and spins == 972) {
            const vbar = geom.view_bar;
            if (maru.chrome.components.dock_view_bar.slotRect(.{ .x = vbar.x, .y = vbar.y, .w = vbar.w, .h = vbar.h }, cell_w, 0)) |r0| {
                const vx: i32 = @intCast(r0.x + r0.w / 2);
                const vy: i32 = @intCast(r0.y + r0.h / 2);
                window.postSyntheticMouse(.left_down, vx, vy);
                window.postSyntheticMouse(.left_up, vx, vy);
            }
        }
        if (smoke and spins == 976 and dock_view == .explorer) {
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .file) continue;
                if (!std.mem.eql(u8, r.file.path, open_target_buf[0..open_target_len])) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const fx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const fy: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, fx, fy);
                window.postSyntheticMouse(.left_up, fx, fy);
                break;
            }
        }
        // **thumb 을 잡아서 끈다** — 트랙 빈 자리를 누르면 "뛰기" 가 되어 다른 규칙을 재게 된다.
        // 자리는 **그린 막대**가 준다(`editor_last_hbar`) — 여기서 산수로 잡으면 그린 자리와 갈린다.
        if (smoke and spins == 980 and active_view == .file) if (editor_last_hbar) |bar| {
            hdrag_judgeable = true;
            hdrag_col_before = open_files.items[active_view.file].first_col;
            hdrag_thumb_before = bar.thumb_x;
            const ox: f32 = @floatFromInt(geom.terminal.x);
            const oy: f32 = @floatFromInt(geom.terminal.y);
            const gx: i32 = @intFromFloat(ox + bar.thumb_x + bar.thumb_w / 2);
            const gy: i32 = @intFromFloat(oy + bar.hit_y + bar.hit_h / 2);
            // 트랙 오른쪽 4 분의 3 지점까지 끈다.
            const tx: i32 = @intFromFloat(ox + bar.track_x + bar.track_w * 0.75);
            window.postSyntheticMouse(.left_down, gx, gy);
            window.postSyntheticMouse(.moved, tx, gy);
            window.postSyntheticMouse(.left_up, tx, gy);
        };
        // ── 굴린 목록이 헤더를 안 뚫는다 (보고 결함 ②) ────────────────────────────────
        //
        // 헤더를 맨 나중에 그리는 것만으로는 안 덮인다 — 글리프는 배경이 투명해서 **글자끼리
        // 포개진다**(실측 캡처: `session 3` 이 `Search` 위에). 이제 목록 셀을 헤더 아래로 자른다.
        //
        // **한 눈금은 카드 높이의 배수가 아니다**(190px vs 57px) — 그래서 첫 카드가 반쯤 잘리고,
        // 그때가 이 판정이 물을 것이 있는 순간이다.
        // **휠로는 이 순간을 못 만든다** — 한 눈금(10 줄 × 19px = 190px)이 카드 높이(38px)의 **정확히
        // 다섯 배**라 늘 경계에 떨어진다(실측 `partial=0`). 픽셀로 움직이는 **막대 트랙 클릭**을 쓴다.
        if (smoke and spins == 1052) if (sidebar_bar) |b| {
            const tx3: i32 = @intFromFloat(b.hit_x + b.hit_w / 2);
            const ty3: i32 = @intFromFloat(b.track_y + b.track_h * 0.37);
            window.postSyntheticMouse(.left_down, tx3, ty3);
            window.postSyntheticMouse(.left_up, tx3, ty3);
        };
        if (smoke and spins == 1055) {
            clip_partial = sidebar_partial;
            clip_over = sidebar_card_over_header;
            clip_clipped = sidebar_cells_clipped;
        }
        // ── 카드가 열여섯을 넘어도 끝까지 굴러간다 (보고 결함 ①) ──────────────────────
        //
        // 그리기는 `cards` 를 끝까지 훑는데 기하·히트테스트·스크롤 상한은 **`[16]` 짜리 배열**로 만든
        // 목록을 봤다 — 열일곱 번째 카드부터는 보이는데 **굴려 갈 수가 없었다**. 세션 상한이 16 이고
        // 연 파일 수에는 상한이 없어 실제로 닿는 자리다.
        //
        // 폴더를 펼쳐 텍스트 파일을 여러 개 열어 카드를 열여섯 너머로 민 뒤, 맨 위에서 바닥까지
        // 굴려 **마지막 카드가 통째로 보이는지** 본다.
        if (smoke and spins == 1034 and dock_view == .explorer) {
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .directory) continue;
                if (!std.mem.endsWith(u8, r.directory.path, "tools")) continue;
                if (r.directory.expanded) break;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const tx2: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const ty2: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, tx2, ty2);
                window.postSyntheticMouse(.left_up, tx2, ty2);
                break;
            }
        }
        if (smoke and spins == 1038 and dock_view == .explorer) {
            var opened: usize = 0;
            for (dock_rows.items, 0..) |r, ri| {
                if (opened >= 20) break;
                if (r != .file) continue;
                const k = maru.session.file_panel_bridge.openKindForPath(r.file.path) orelse continue;
                if (k != .text) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const ox2: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const oy2: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, ox2, oy2);
                window.postSyntheticMouse(.left_up, ox2, oy2);
                opened += 1;
            }
        }
        // **도크를 한 눈금 내려 다른 줄에서도 연다** — 한 화면 안의 파일만으로는 카드가 열여섯을
        // 못 넘는다(실측 `cards=16`, 딱 하나 모자랐다).
        if (smoke and spins == 1040 and dock_view == .explorer) {
            const wx3: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
            const wy3: i32 = @intCast(geom.tree_content.y + geom.tree_content.h / 2);
            window.postSyntheticMouseWheel(.wheel, wx3, wy3, -1);
        }
        if (smoke and spins == 1041 and dock_view == .explorer) {
            var opened2: usize = 0;
            for (dock_rows.items, 0..) |r, ri| {
                if (opened2 >= 8) break;
                if (r != .file) continue;
                const k = maru.session.file_panel_bridge.openKindForPath(r.file.path) orelse continue;
                if (k != .text) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const ox3: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const oy3: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, ox3, oy3);
                window.postSyntheticMouse(.left_up, ox3, oy3);
                opened2 += 1;
            }
        }
        // **맨 위로 되돌린 뒤 바닥까지 굴린다** — 여는 순간의 "눈이 따라간다"(W8.18a)가 이미 옮겨
        // 놓은 자리를 재면 휠 상한을 안 묻게 된다.
        if (smoke and spins == 1042) {
            const cx3: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const cy3: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            var un: usize = 0;
            while (un < 20) : (un += 1) window.postSyntheticMouseWheel(.wheel, cx3, cy3, 3);
        }
        if (smoke and spins == 1046) {
            const cx4: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const cy4: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            var dn2: usize = 0;
            while (dn2 < 20) : (dn2 += 1) window.postSyntheticMouseWheel(.wheel, cx4, cy4, -3);
        }
        if (smoke and spins == 1050 and sidebar_header_h != 0 and sidebar_cards.items.len > 0) {
            cap_cards = sidebar_cards.items.len;
            cap_off = sidebar_scroll_px;
            // **그린 쪽 값이다**(빌더가 낸다 — 판정이 다시 계산하지 않는다). 마지막 카드까지 그렸으면
            // `first + visible == cards` 다.
            cap_first_visible = sidebar_first_visible;
            cap_visible = sidebar_cards_visible;
            const rws_cap = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            cap_rows = rws_cap.len;
            if (rws_cap.len > 0) {
                const m_cap = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
                const last = rws_cap.len - 1;
                const top_cap = maru.chrome.components.sidebar.rowTop(rws_cap, last, sidebar_header_h, m_cap, sidebar_scroll_px);
                const bot_cap = top_cap + @as(i64, maru.chrome.components.sidebar.rowHeight(rws_cap[last], m_cap));
                cap_last_visible = top_cap >= @as(i64, sidebar_header_h) and bot_cap <= @as(i64, geom.sidebar.h);
            }
        }
        // ── 목록이 줄어도 도크가 자기 범위 안에 있는다 (W8.18b) ───────────────────────
        //
        // **접기·정렬·새로고침은 목록을 줄인다.** 그때 스크롤을 그대로 두면 내용이 없는 자리를 보게
        // 된다 — 편집기가 겪은 그 실패(`first=1000000` 에서 빈 문서)의 도크 짝이고, macOS 는 행을
        // 다시 지을 때마다 `clampFileTreeScroll` 을 부른다.
        //
        // 큰 폴더를 펼쳐 굴릴 여지를 만든 뒤(끝의 트리는 31 행이라 52px 밖에 안 굴러간다) 바닥까지
        // 굴리고, 그 폴더를 다시 접는다.
        if (smoke and spins == 1012 and dock_view == .explorer) {
            // **아래쪽 폴더를 고른다.** 위쪽 줄을 고르면 굴린 뒤 그 줄이 화면 밖이라 되접을 수가
            // 없다(실측: 판정이 통째로 unjudgeable 이었다). 한 눈금이 190px 이므로 그보다 아래.
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .directory) continue;
                if (r.directory.expanded) continue;
                if (ri * cell_h < 220) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                dclamp_row = ri;
                dclamp_expanded = true;
                const ex: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const ey: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, ex, ey);
                window.postSyntheticMouse(.left_up, ex, ey);
                break;
            }
        }
        // ── 표면마다 나머지가 따로다 (W8.18b 에서 걸린 것) ─────────────────────────────
        //
        // **한 눈금 미만을 사이드바에 흘린 뒤 도크를 한 눈금 굴린다.** 누적기를 나눠 쓰면 그 나머지가
        // 도크의 첫 눈금을 먹어 **도크가 안 굴러간다** — 실측으로 이 슬라이스의 시험이 거기 막혔다.
        if (smoke and spins == 1016) {
            leak_judgeable = true;
            leak_sidebar_before = sidebar_scroll_px;
            leak_dock_before = dock_scroll_px;
            const lx: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const ly: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            window.postSyntheticMouseWheelDelta(.wheel, lx, ly, 40);
        }
        if (smoke and spins == 1018 and leak_judgeable) leak_sidebar_after = sidebar_scroll_px;
        if (smoke and spins == 1022 and leak_judgeable) leak_dock_after = dock_scroll_px;
        if (smoke and spins == 1020 and dclamp_expanded) {
            const dsx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
            const dsy: i32 = @intCast(geom.tree_content.y + geom.tree_content.h / 2);
            // **한 눈금만 굴린다**(= 10 줄 × 19px = 190px). 접힌 뒤 상한(52px)을 넘기면 충분하고,
            // 더 굴리면 되접을 줄이 화면 밖으로 나간다.
            window.postSyntheticMouseWheel(.wheel, dsx, dsy, -1);
        }
        if (smoke and spins == 1024 and dclamp_expanded and dclamp_row < dock_rows.items.len) {
            dclamp_judgeable = true;
            dclamp_off_before = dock_scroll_px;
            dclamp_rows_before = dock_rows.items.len;
            // **같은 폴더 줄을 다시 누른다** — 그 사이 굴렸으므로 화면 자리는 다시 잰다.
            const local = @as(i64, @intCast(dclamp_row * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
            if (local >= 0 and local < @as(i64, @intCast(geom.tree_content.h))) {
                const cx2: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const cy2: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, cx2, cy2);
                window.postSyntheticMouse(.left_up, cx2, cy2);
            } else {
                // 접을 줄이 화면 밖이면 이 판정은 아무것도 안 묻는다 — 그렇게 말한다.
                dclamp_judgeable = false;
            }
        }
        if (smoke and spins == 1030 and dclamp_judgeable) {
            dclamp_off_after = dock_scroll_px;
            dclamp_rows_after = dock_rows.items.len;
            dclamp_drawn_after = dock_rows_drawn;
            // **빌더가 실제로 쓴 첫 행**이다(여기서 다시 계산하지 않는다) — 값만 되돌리고 셀을 다시
            // 안 지으면 이 값이 옛 offset 그대로다.
            dclamp_draw_start_after = dock_draw_start;
        }
        // ── 눈이 따라간다 (W8.18a) ───────────────────────────────────────────────────
        //
        // **먼저 목록을 맨 위로 굴린다** — 세션이 열셋이라 파일 카드는 바닥에 있고, 위에서 보면
        // 화면 밖이다. 그 상태에서 도크의 파일 행을 누르면(사이드바가 아니라 **도크**다 — 그쪽은
        // 늘 보인다) 사이드바가 그 카드로 따라와야 한다.
        // **먼저 목록이 넘치게 만든다.** 이 시점의 세션은 일곱이라 카드가 다 들어간다 — 그 상태로
        // 재면 "이미 보이는 것이 보인다" 는 빈 판정이다. 파일을 몇 개 더 열어(그것이 이 기능의 실제
        // 사용처다) 마지막 카드를 화면 밖으로 민다.
        if (smoke and spins == 996 and dock_view == .explorer) {
            var opened_more: usize = 0;
            for (dock_rows.items, 0..) |r, ri| {
                if (opened_more >= 4) break;
                if (r != .file) continue;
                const k = maru.session.file_panel_bridge.openKindForPath(r.file.path) orelse continue;
                if (k != .text) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const ox: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const oy: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, ox, oy);
                window.postSyntheticMouse(.left_up, ox, oy);
                opened_more += 1;
            }
        }
        // **마지막으로 연 파일의 경로를 챙긴다** — 그 카드가 목록 맨 아래라 맨 위에서 보면 화면
        // 밖이다. 끝 상태에서 다시 고르면 그 사이 목록이 바뀌어 다른 줄을 누르게 된다.
        if (smoke and spins == 997 and open_files.items.len > 0) {
            const lp = open_files.items[open_files.items.len - 1].path;
            reveal_path_len = @min(lp.len, reveal_path_buf.len);
            @memcpy(reveal_path_buf[0..reveal_path_len], lp[0..reveal_path_len]);
        }
        if (smoke and spins == 998) {
            const rx: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const ry: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            var rn: usize = 0;
            while (rn < 12) : (rn += 1) window.postSyntheticMouseWheel(.wheel, rx, ry, 3);
        }
        if (smoke and spins == 1000 and dock_view == .explorer and sidebar_header_h != 0) {
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .file) continue;
                if (!std.mem.eql(u8, r.file.path, reveal_path_buf[0..reveal_path_len])) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                reveal_judgeable = true;
                reveal_slot = sidebarActiveSlot(sidebar_cards.items, active_view);
                reveal_visible_before = sidebarSlotFullyVisible(allocator, &sidebar_rows_scratch, sidebar_cards.items, active_view, sidebar_header_h, cell_h, geom.sidebar.h, sidebar_scroll_px);
                reveal_off_before = sidebar_scroll_px;
                reveal_digest_before = d3d11_cells.cellsDigest(sidebar_cells.items);
                const fx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const fy: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, fx, fy);
                window.postSyntheticMouse(.left_up, fx, fy);
                break;
            }
        }
        if (smoke and spins == 1003 and reveal_judgeable) {
            reveal_slot_after = sidebarActiveSlot(sidebar_cards.items, active_view);
            reveal_visible_after = sidebarSlotFullyVisible(allocator, &sidebar_rows_scratch, sidebar_cards.items, active_view, sidebar_header_h, cell_h, geom.sidebar.h, sidebar_scroll_px);
            reveal_off_after = sidebar_scroll_px;
            reveal_digest_after = d3d11_cells.cellsDigest(sidebar_cells.items);
            reveal_count = sidebar_reveals;
        }
        // ── 트랙 빈 자리를 누르면 그 자리로 뛴다 (적대적 검증 3회차) ─────────────────
        //
        // 드래그와 **다른 길**이다(`begin` 이 offset 을 돌려주는 쪽). 판정은 "값이 바뀌었나" 가
        // 아니라 **누른 자리가 새 thumb 안에 들어왔나** 로 본다 — 중립이 약속한 것이 그것이고
        // (*"그 지점에 thumb 중앙을 놓는다"*), 자리 계산을 여기서 되풀이하면 동어반복이 된다.
        if (smoke and spins == 992 and active_view == .file) if (editor_last_hbar) |bar| {
            jump_judgeable = true;
            jump_col_before = open_files.items[active_view.file].first_col;
            jump_local_x = bar.track_x + bar.track_w * 0.9;
            const jx: i32 = @intFromFloat(@as(f32, @floatFromInt(geom.terminal.x)) + jump_local_x);
            const jy: i32 = @intFromFloat(@as(f32, @floatFromInt(geom.terminal.y)) + bar.hit_y + bar.hit_h / 2);
            jump_on_thumb_before = bar.thumbContains(jump_local_x);
            window.postSyntheticMouse(.left_down, jx, jy);
            window.postSyntheticMouse(.left_up, jx, jy);
        };
        if (smoke and spins == 994 and jump_judgeable and active_view == .file) {
            jump_col_after = open_files.items[active_view.file].first_col;
            jump_on_thumb_after = if (editor_last_hbar) |b| b.thumbContains(jump_local_x) else false;
        }
        // ── 축이 나머지를 안 나눠 쓴다 (적대적 검증 2회차) ────────────────────────────
        //
        // 정밀 터치패드는 `WHEEL_DELTA`(120) 미만을 보내고 누적기가 그 나머지를 들고 있는다. 축이
        // 그것을 **나눠 쓰면** 가로로 조금 민 것이 세로 한 줄로 튄다 — 대각선 제스처에서 늘 난다.
        // 눈금 배수로는 안 보인다(나머지가 0 이라). 그래서 **눈금 미만**으로 던진다.
        if (smoke and spins == 988 and active_view == .file) {
            axis_judgeable = true;
            axis_col_before = open_files.items[active_view.file].first_col;
            axis_line_before = open_files.items[active_view.file].first_line;
            const ax: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const ay: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            // **부호를 맞춰야 섞인다.** 40 과 -80 은 서로를 지워 한 눈금이 안 된다 — 실측으로
            // 나머지를 나눠 쓰는 뮤턴트가 그 조합에서 살아남았다. 둘 다 음수로 던져 합이 -120 이
            // 되게 한다(그러면 세로가 아래로 한 눈금 굴러 `first_line` 이 0 에서 움직인다).
            window.postSyntheticMouseWheelDelta(.wheel_h, ax, ay, -40);
            window.postSyntheticMouseWheelDelta(.wheel, ax, ay, -80);
        }
        if (smoke and spins == 990 and axis_judgeable and active_view == .file) {
            axis_col_after = open_files.items[active_view.file].first_col;
            axis_line_after = open_files.items[active_view.file].first_line;
        }
        if (smoke and spins == 984 and hdrag_judgeable and active_view == .file) {
            hdrag_col_after = open_files.items[active_view.file].first_col;
            hdrag_thumb_after = if (editor_last_hbar) |b| b.thumb_x else 0;
            hdrag_drags = editor_hdrags;
        }
        // ── 확인 모달 (W8.16b) ─────────────────────────────────────────────────────────
        //
        // **프롬프트 마크가 없는 세션**의 ✕ 를 눌러 모달을 띄운다 — 그 갈래가 §2m.77 이 "모달이
        // 선행" 이라 남겨 둔 자리다. 그리고 **Enter 로 승낙**해 실제로 닫히는지 본다.
        if (smoke and spins == 900 and sessions.items.len >= 3 and sidebar_card_columns != null) {
            modal_judgeable = true;
            modal_sessions_before = sessions.items.len;
            const rr6 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm6 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const top6 = maru.chrome.components.sidebar.rowTop(rr6, 1, sidebar_header_h, mm6, sidebar_scroll_px);
            const cy6: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top6) + @as(i64, @intCast(cell_h / 2)));
            const rng6 = sidebar_card_columns.?.closeXRange(cell_w);
            const cx6: i32 = @intCast(@as(i64, @intFromFloat(rng6.start)) + @as(i64, @intCast(cell_w / 2)));
            window.postSyntheticMouse(.moved, cx6, cy6);
            window.postSyntheticMouse(.left_down, cx6, cy6);
            window.postSyntheticMouse(.left_up, cx6, cy6);
        }
        // **자기 모달 주기를 연다.** 앞선 판정과 같은 모달을 쓰면 서로의 기대를 깨뜨린다 —
        // "열려 있는 동안 세션이 안 준다" 와 "일부러 줄인다" 는 한 모달에 같이 못 산다(실측으로
        // `confirm_modal_ok` 를 한 번 빨갛게 만들었다).
        if (smoke and spins == 936 and sessions.items.len >= 3 and sidebar_card_columns != null) {
            const rr8 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm8 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const top8 = maru.chrome.components.sidebar.rowTop(rr8, 1, sidebar_header_h, mm8, sidebar_scroll_px);
            const cy8: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top8) + @as(i64, @intCast(cell_h / 2)));
            const rng8 = sidebar_card_columns.?.closeXRange(cell_w);
            const cx8: i32 = @intCast(@as(i64, @intFromFloat(rng8.start)) + @as(i64, @intCast(cell_w / 2)));
            window.postSyntheticMouse(.moved, cx8, cy8);
            window.postSyntheticMouse(.left_down, cx8, cy8);
            window.postSyntheticMouse(.left_up, cx8, cy8);
        }
        if (smoke and spins == 944 and shift_judgeable) window.postSyntheticVirtualKey(win32_keys.vk_return);
        // ── 열고 닫기를 되풀이한다 (적대적 검증 5회차) ─────────────────────────────────
        //
        // **한 번만 열면 쌓이는 것이 안 보인다.** 모달 프레임은 매 프레임 새로 만들고 앞 것을 놓는데,
        // 그 짝이 어긋나면 열 때마다 샌다. 누수 보고와 함께 **여는 데 드는 셀 수가 일정한지**도 본다.
        if (smoke and spins >= 952 and spins <= 968 and @mod(spins, 4) == 0 and sessions.items.len >= 3 and sidebar_card_columns != null and !confirm_state.open) {
            const rr9 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm9 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const top9 = maru.chrome.components.sidebar.rowTop(rr9, 1, sidebar_header_h, mm9, sidebar_scroll_px);
            const cy9: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top9) + @as(i64, @intCast(cell_h / 2)));
            const rng9 = sidebar_card_columns.?.closeXRange(cell_w);
            const cx9: i32 = @intCast(@as(i64, @intFromFloat(rng9.start)) + @as(i64, @intCast(cell_w / 2)));
            window.postSyntheticMouse(.moved, cx9, cy9);
            window.postSyntheticMouse(.left_down, cx9, cy9);
            window.postSyntheticMouse(.left_up, cx9, cy9);
            cycle_opens += 1;
        }
        // 연 뒤 Esc — 열고 닫기를 되풀이한다.
        if (smoke and spins >= 954 and spins <= 970 and @mod(spins, 4) == 2 and confirm_state.open) {
            if (cycle_first_cells == 0) cycle_first_cells = confirm_cells_drawn;
            cycle_last_cells = confirm_cells_drawn;
            window.postSyntheticVirtualKey(win32_keys.vk_escape);
            cycle_closes += 1;
        }
        // ── 목록이 밀려도 지목한 그것이 닫히나 (적대적 검증 3회차) ────────────────────
        //
        // 모달이 떠 있는 동안 **다른** 세션이 사라지면 보류한 대상이 무엇을 가리키나. 번호를 들면
        // 밀려서 **엉뚱한 세션이 죽는다** — 지금은 입력을 삼켜 그 일이 안 일어나지만, 셸이 끝난
        // 세션을 걷어내는 한 줄만 생겨도 도달한다. id 를 들면 안 밀린다.
        if (smoke and spins == 940 and confirm_state.open and sessions.items.len >= 3) {
            shift_judgeable = true;
            const victim = sessions.items[1].surface.id;
            const s0 = sessions.items[0];
            s0.surface.lockCore(io);
            s0.surface.core.write("\x1b]133;A\x1b\\") catch {};
            s0.surface.core.write("\x1b]133;B\x1b\\") catch {};
            s0.surface.unlockCore(io);
            _ = closeWinSession(allocator, io, &sessions, &tab_ptrs, &app_window, &runtime, 0, true);
            pump = sessions.items[0].pump;
            probe_victim_id = victim;
        }
        if (smoke and spins == 948 and shift_judgeable) {
            var still: bool = false;
            for (sessions.items) |s| if (s.surface.id == probe_victim_id) {
                still = true;
            };
            shift_target_survived = still;
        }
        if (smoke and spins == 904 and modal_judgeable) {
            modal_open_after_click = confirm_state.open;
            modal_cells = confirm_cells_drawn;
            modal_sessions_while_open = sessions.items.len;
            // **Enter 로 승낙한다** — 중립 `confirm.handle` 이 포커스된 버튼을 실행한다.
            window.postSyntheticVirtualKey(win32_keys.vk_return);
        }
        // ── 취소 갈래 (적대적 검증 1회차) ──────────────────────────────────────────────
        //
        // **승낙만 밀면 절반이다.** 취소가 아무 일도 안 하는지(세션이 그대로인지), 그리고 모달이
        // 닫히는지를 따로 본다 — 취소가 닫기를 실행하면 그것이 가장 나쁜 결함이다.
        if (smoke and spins == 914 and sessions.items.len >= 3 and sidebar_card_columns != null) {
            cancel_judgeable = true;
            cancel_sessions_before = sessions.items.len;
            const rr7 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm7 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const top7 = maru.chrome.components.sidebar.rowTop(rr7, 1, sidebar_header_h, mm7, sidebar_scroll_px);
            const cy7: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top7) + @as(i64, @intCast(cell_h / 2)));
            const rng7 = sidebar_card_columns.?.closeXRange(cell_w);
            const cx7: i32 = @intCast(@as(i64, @intFromFloat(rng7.start)) + @as(i64, @intCast(cell_w / 2)));
            window.postSyntheticMouse(.moved, cx7, cy7);
            window.postSyntheticMouse(.left_down, cx7, cy7);
            window.postSyntheticMouse(.left_up, cx7, cy7);
        }
        // ── 모달이 떠 있어도 창 버튼은 살아 있어야 한다 (적대적 검증 2회차) ────────────
        //
        // **삼킴이 너무 넓으면 갇힌다.** 모달 뒤의 카드·트리는 막아야 하지만 창의 최소화·최대화까지
        // 죽으면 사용자가 빠져나갈 길이 줄어든다 — OS 창 조작은 앱 모달의 대상이 아니다.
        if (smoke and spins == 916 and cancel_judgeable and confirm_state.open) {
            capmodal_judgeable = true;
            capmodal_before = window.isMaximized();
            // **모달이 창을 따라오는가.** 창이 커졌는데 상자가 옛 자리에 남으면 가운데가 아니게 된다 —
            // 셀 수만 보면 같은 글자라 안 움직인다. **지문**과 **가로 중앙**을 함께 본다.
            resize_cells_before = confirm_cells_drawn;
            resize_center_before = confirm_center_x;
            resize_client_before = client_w;
            const caps = captionButtonRects(client_w, titlebar_px, caption_btn_w);
            const mx: i32 = @intCast(caps[1].x + caps[1].w / 2); // ☐ 최대화
            const my: i32 = @intCast(caps[1].y + caps[1].h / 2);
            window.postSyntheticMouse(.moved, mx, my);
            window.postSyntheticMouse(.left_down, mx, my);
            window.postSyntheticMouse(.left_up, mx, my);
        }
        if (smoke and spins == 921 and capmodal_judgeable) {
            capmodal_after = window.isMaximized();
            resize_cells_after = confirm_cells_drawn;
            resize_center_after = confirm_center_x;
            resize_client_after = client_w;
            resize_open_after = confirm_state.open;
            // **되돌린다.** 최대화한 채로 두면 뒤따르는 판정이 다른 크기의 창을 본다 — 실측으로
            // `dock_scroll` 이 `content_fits` 로 바뀌었다.
            const caps2 = captionButtonRects(client_w, titlebar_px, caption_btn_w);
            const rx: i32 = @intCast(caps2[1].x + caps2[1].w / 2);
            const ry: i32 = @intCast(caps2[1].y + caps2[1].h / 2);
            window.postSyntheticMouse(.moved, rx, ry);
            window.postSyntheticMouse(.left_down, rx, ry);
            window.postSyntheticMouse(.left_up, rx, ry);
        }
        if (smoke and spins == 926 and cancel_judgeable) {
            cancel_open_before = confirm_state.open;
            window.postSyntheticVirtualKey(win32_keys.vk_escape);
        }
        if (smoke and spins == 930 and cancel_judgeable) {
            cancel_open_after = confirm_state.open;
            cancel_sessions_after = sessions.items.len;
        }
        if (smoke and spins == 910 and modal_judgeable) {
            modal_open_after_accept = confirm_state.open;
            modal_sessions_after = sessions.items.len;
        }
        // ── 거절은 상태를 안 건드린다 (적대적 검증 4회차) ──────────────────────────────
        //
        // **부분 적용이 가장 나쁘다.** 라우팅만 끊고 목록에 남거나, 목록에서 뺐는데 살아 있으면
        // 화면과 실물이 갈린다. 실행 중인 세션에 닫기를 걸어 **아무것도 안 변하는지** 본다.
        if (smoke and spins == 896 and sessions.items.len >= 3) {
            // 프롬프트 마크를 **안** 준 세션(1번)은 `unknown` 이라 중립 술어가 "실행 중" 으로 본다.
            busy_judgeable = true;
            busy_sessions_before = sessions.items.len;
            busy_tabs_before = app_window.tabs.len;
            busy_active_before = app_window.active_tab;
            busy_result_busy = closeWinSession(allocator, io, &sessions, &tab_ptrs, &app_window, &runtime, 1, false) == .busy_needs_confirm;
            busy_sessions_after = sessions.items.len;
            busy_tabs_after = app_window.tabs.len;
            busy_active_after = app_window.active_tab;
            // **그 세션이 아직 살아 있는가** — 큐 포인터로 확인한다(해제됐으면 이 값이 안 맞는다).
            // **런타임에 직접 묻는다.** 처음에는 세션의 큐 포인터를 자기 자신과 견줬는데, 둘 다
            // 같은 `live` 에서 나오는 **동어반복**이라 라우팅만 끊는 뮤턴트가 그대로 통과했다
            // (적대적 검증 4회차 실측). 라우팅이 살아 있는지는 런타임만 안다.
            busy_still_alive = blk_alive: {
                if (sessions.items.len <= 1) break :blk_alive false;
                // 빈 입력이라 셸에 아무것도 안 간다 — 묻는 것은 **라우팅이 아직 있는가**뿐이다.
                _ = runtime.writeInputNonBlocking(sessions.items[1].surface.id, "") catch |e| {
                    break :blk_alive e != error.UnknownSurface;
                };
                break :blk_alive true;
            };
        }
        // ── 연달아 닫는다 (적대적 검증 3회차) ──────────────────────────────────────────
        //
        // 한 번만 닫으면 순서에 기대는 실수가 안 드러난다 — 색인·활성·id 가 **누적으로** 어긋나는지
        // 본다. 매번 프롬프트 마크를 먹여 성공 갈래로 민다.
        if (smoke and spins >= 880 and spins <= 890 and @mod(spins, 2) == 0 and sessions.items.len >= 3) {
            const s0 = sessions.items[0];
            s0.surface.lockCore(io);
            s0.surface.core.write("\x1b]133;A\x1b\\") catch {};
            s0.surface.core.write("\x1b]133;B\x1b\\") catch {};
            s0.surface.unlockCore(io);
            switch (closeWinSession(allocator, io, &sessions, &tab_ptrs, &app_window, &runtime, 0, false)) {
                .closed => {
                    multi_closes += 1;
                    pump = sessions.items[0].pump;
                    if (active_view == .terminal) active_view = .{ .terminal = app_window.active_tab };
                    refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                },
                else => {},
            }
        }
        if (smoke and spins == 894) {
            multi_sessions = sessions.items.len;
            multi_tabs = app_window.tabs.len;
            multi_active_ok = app_window.active_tab < sessions.items.len;
            var dup2: usize = 0;
            for (sessions.items, 0..) |a, i| {
                for (sessions.items[i + 1 ..]) |b| {
                    if (a.surface.id == b.surface.id) dup2 += 1;
                }
            }
            multi_dups = dup2;
        }
        if (smoke and spins == 874 and sclose_judgeable and sessions.items.len < max_win_sessions) {
            if (app_window.active()) |a| spawn_opts.size = a.core.size;
            // **판정을 먼저 켠다.** 실패했을 때 판정이 사라지면(`unjudgeable`) 빨간 줄이 안 나오고,
            // 없는 줄은 눈에 안 띈다 — 실측으로 옛 동작 뮤턴트가 그렇게 조용히 지나갔다.
            idcheck_judgeable = true;
            if (spawnWinSession(allocator, &sessions, &tab_ptrs, &app_window, &runtime, &next_session_id, spawn_opts)) {
                idcheck_spawned = true;
                // **제품의 ＋ 경로가 하는 것을 그대로 한다** — 목록을 안 새로 지으면 카드 수가
                // 세션 수와 갈린다(`lists_agree` 가 그것을 잡았다).
                refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
            } else |e| {
                idcheck_err_len = @min(@errorName(e).len, idcheck_err.len);
                @memcpy(idcheck_err[0..idcheck_err_len], @errorName(e)[0..idcheck_err_len]);
            }
        }
        if (smoke and spins == 878 and idcheck_spawned) {
            var dup: usize = 0;
            for (sessions.items, 0..) |a, i| {
                for (sessions.items[i + 1 ..]) |b| {
                    if (a.surface.id == b.surface.id) dup += 1;
                }
            }
            idcheck_dups = dup;
            idcheck_count = sessions.items.len;
        }
        if (smoke and spins == 872 and sclose_judgeable) {
            sclose_sessions_after = sessions.items.len;
            sclose_tabs_after = app_window.tabs.len;
            sclose_first_name_len = if (sessions.items.len > 0) @min(sessions.items[0].label().len, sclose_first_name.len) else 0;
            if (sclose_first_name_len > 0) @memcpy(sclose_first_name[0..sclose_first_name_len], sessions.items[0].label()[0..sclose_first_name_len]);
            sclose_active_ok = app_window.active_tab < sessions.items.len;
            // **루프가 든 pump 가 살아 있는 세션 것인가.** 첫 세션을 닫으면 그 pump 는 해제된
            // 메모리를 가리킨다 — 그런데 **아무 증상도 안 났다**(뮤턴트가 크래시도 판정도 안 냈다).
            // 큐 포인터를 견주는 것이 그 use-after-free 를 잡는 유일한 값이다.
            sclose_pump_rebound = sessions.items.len > 0 and pump.queue == sessions.items[0].pump.queue;
            // **보고 있던 세션이 그대로인가.** 앞쪽을 닫으면 뒤 색인이 하나씩 당겨지는데 활성 번호를
            // 그대로 두면 **다른 세션을 보게 된다** — 화면은 멀쩡해 보이고 개수 판정도 초록이다.
            sclose_active_name_len = if (app_window.active_tab < sessions.items.len)
                @min(sessions.items[app_window.active_tab].label().len, sclose_active_name.len)
            else
                0;
            if (sclose_active_name_len > 0)
                @memcpy(sclose_active_name[0..sclose_active_name_len], sessions.items[app_window.active_tab].label()[0..sclose_active_name_len]);
        }
        // ── 에이전트 도크 검색 (W8.15 나머지) ──────────────────────────────────────────
        //
        // **탐색기가 아니라 에이전트 뷰여야 한다** — 그 검색 줄은 그 뷰에만 있다.
        if (smoke and spins == 836 and geom.view_bar.w != 0) {
            const bar_a = maru.chrome.components.dock_view_bar.Rect{ .x = geom.view_bar.x, .y = geom.view_bar.y, .w = geom.view_bar.w, .h = geom.view_bar.h };
            if (maru.chrome.components.dock_view_bar.slotRect(bar_a, cell_w, 2)) |ra| {
                const ax2: i32 = @intCast(ra.x + ra.w / 2);
                const ay2: i32 = @intCast(ra.y + ra.h / 2);
                window.postSyntheticMouse(.left_down, ax2, ay2);
                window.postSyntheticMouse(.left_up, ax2, ay2);
            }
        }
        // **검색 줄을 누른다.** 자리는 published tree 가 준다(손으로 고르면 배치가 바뀌어도 안 움직인다).
        if (smoke and spins == 842) if (agent_built) |*b| {
            const sid = maru.chrome.components.session_dock.build.NodeIds.search;
            for (b.frame.tree.entries) |e| {
                if (e.id != sid) continue;
                asearch_judgeable = true;
                asearch_items_before = agent_items.items.len;
                const qx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(e.rect.x + e.rect.width / 2)));
                const qy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(e.rect.y + e.rect.height / 2)));
                window.postSyntheticMouse(.left_down, qx, qy);
                window.postSyntheticMouse(.left_up, qx, qy);
                break;
            }
        };
        if (smoke and spins == 848) if (asearch_judgeable) {
            asearch_focused = agent_search_focused;
            // 이 기계 이력에 없을 법한 글자 — 걸리는 것이 없어야 한다.
            for ("zzqx") |ch| window.postSyntheticChar(ch);
        };
        if (smoke and spins == 854) if (asearch_judgeable) {
            asearch_items_after = agent_items.items.len;
            var k2: usize = 0;
            while (k2 < 4) : (k2 += 1) window.postSyntheticVirtualKey(win32_keys.vk_back);
        };
        if (smoke and spins == 860 and asearch_judgeable) asearch_items_restored = agent_items.items.len;
        // ── 검색에 글자를 친다 (W8.15) ─────────────────────────────────────────────────
        //
        // **검색 줄을 누르고 글자를 친다.** 그 줄은 §2m.46 이후 그려만 있고 죽어 있었다.
        if (smoke and spins == 816 and sidebar_header_h != 0) {
            const sxq: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            // **아래 판정이 쓰는 그 식이다** — 검색 밴드의 세로 한가운데다(`headerSearchBandTop`
            // 위). 손으로 다르게 잡으면 밴드를 빗나가 `.search` 가 안 나온다(실측으로 그랬다).
            const syq: i32 = @intCast(geom.sidebar.y + (sidebar_header_icon_band + sidebar_header_h) / 2);
            window.postSyntheticMouse(.moved, sxq, syq);
            window.postSyntheticMouse(.left_down, sxq, syq);
            window.postSyntheticMouse(.left_up, sxq, syq);
        }
        if (smoke and spins == 818) {
            search_judgeable = true;
            search_cards_before = sidebar_cards.items.len;
            search_focused_after_click = search_focused;
            // "session" 은 세션 카드만 걸린다 — 파일 카드(`build.zig` 등)는 빠져야 한다.
            for ("session") |ch| window.postSyntheticChar(ch);
        }
        if (smoke and spins == 824) {
            search_cards_after = sidebar_cards.items.len;
            search_query_drawn = search.query.items.len;
            search_sessions_after = blk: {
                var n: usize = 0;
                for (sidebar_cards.items) |c| if (c.source == .session) {
                    n += 1;
                };
                break :blk n;
            };
            search_files_after = blk2: {
                var n: usize = 0;
                for (sidebar_cards.items) |c| if (c.source == .file) {
                    n += 1;
                };
                break :blk2 n;
            };
            // **지운다** — 되돌아오는지가 필터가 상태를 안 망가뜨렸다는 증거다.
            var k: usize = 0;
            while (k < 7) : (k += 1) window.postSyntheticVirtualKey(win32_keys.vk_back);
        }
        if (smoke and spins == 830) search_cards_restored = sidebar_cards.items.len;
        // ── ✕ 로 파일 카드를 닫는다 (W8.14) ────────────────────────────────────────────
        //
        // **둘을 열어 두고 하나만 닫는다.** 하나만 열고 닫으면 "목록이 비었다" 와 "그 하나가
        // 지워졌다" 가 같은 그림이라, 색인이 밀리는 실수를 못 본다.
        if (smoke and spins == 786) if (dock_view == .explorer) {
            for (dock_rows.items, 0..) |r, ri| {
                if (r != .file) continue;
                if (std.mem.eql(u8, r.file.path, open_target_buf[0..open_target_len])) continue;
                // **중립 규칙으로 고른다** — 확장자를 여기서 다시 나열하면 그 표가 두 곳이 된다.
                // 루트에 `.zig` 는 하나뿐이라 그것으로는 둘째 파일을 못 연다(실측).
                const k = maru.session.file_panel_bridge.openKindForPath(r.file.path) orelse continue;
                if (k != .text) continue;
                const local = @as(i64, @intCast(ri * cell_h)) - @as(i64, @intCast(dock_scroll_px)) + @as(i64, @intCast(cell_h / 2));
                if (local < 0 or local >= @as(i64, @intCast(geom.tree_content.h))) continue;
                const sx: i32 = @intCast(geom.tree_content.x + geom.tree_content.w / 2);
                const sy: i32 = @intCast(@as(i64, @intCast(geom.tree_content.y)) + local);
                window.postSyntheticMouse(.left_down, sx, sy);
                window.postSyntheticMouse(.left_up, sx, sy);
                break;
            }
        };
        // **먼저 사이드바를 바닥까지 굴린다.** 이 스모크는 세션이 13 개라 파일 카드가 **화면 밖**이다.
        //
        // > 그것 자체가 하나의 발견이다 — **파일을 열면 활성이 되는데 사이드바가 거기로 안 굴러간다.**
        // > 제품(세션 하나)에서는 안 보이지만, 세션이 쌓이면 "열었는데 아무 표시가 없다" 가 된다.
        // > 이 슬라이스 밖이라 안 고치고 한계에 적는다.
        if (smoke and spins == 787 and geom.sidebar.w != 0) {
            const sx0: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const sy0: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            var k: usize = 0;
            while (k < 12) : (k += 1) window.postSyntheticMouseWheel(.wheel, sx0, sy0, -3);
        }
        // **첫 파일 카드의 ✕ 를 누른다** — 지금 보고 있는 것은 둘째다.
        if (smoke and spins == 790) if (open_files.items.len >= 2 and sidebar_card_columns != null) {
            close_judgeable = true;
            close_files_before = open_files.items.len;
            const wn = open_files.items[1].name();
            close_want_len = @min(wn.len, close_want_buf.len);
            @memcpy(close_want_buf[0..close_want_len], wn[0..close_want_len]);
            const rr3 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm3 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const slot = sessions.items.len; // 첫 파일 카드
            const top = maru.chrome.components.sidebar.rowTop(rr3, slot, sidebar_header_h, mm3, sidebar_scroll_px);
            const cy: i32 = @intCast(@as(i64, @intCast(geom.sidebar.y)) + @as(i64, top) + @as(i64, @intCast(cell_h / 2)));
            const rng = sidebar_card_columns.?.closeXRange(cell_w);
            const cx: i32 = @intCast(@as(i64, @intFromFloat(rng.start)) + @as(i64, @intCast(cell_w / 2)));
            close_click_x = cx;
            window.postSyntheticMouse(.moved, cx, cy);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
        };
        if (smoke and spins == 793) if (close_judgeable) {
            close_files_after = open_files.items.len;
            const gn = if (open_files.items.len > 0) open_files.items[0].name() else "";
            close_got_len = @min(gn.len, close_got_buf.len);
            @memcpy(close_got_buf[0..close_got_len], gn[0..close_got_len]);
            close_view_ok = switch (active_view) {
                .file => |f| f < open_files.items.len,
                .terminal => true,
            };
        };
        // ── 파일을 보는 중에도 디바이더는 끌린다 (적대적 검증 5회차) ────────────────────
        //
        // 문서 위 클릭을 삼키는 코드가 **터미널 영역 안**에 있어야 한다. 더 위로 올라가면 디바이더·
        // 사이드바·도크까지 함께 죽는데, 그것은 화면만 보고는 "원래 그런가" 싶은 종류다.
        if (smoke and spins == 795 and active_view == .file and geom.divider.w != 0) {
            divfile_judgeable = true;
            divfile_dock_w_before = geom.dock.w;
            const gx2: i32 = @intCast(geom.divider.x + geom.divider.w / 2);
            window.postSyntheticMouse(.left_down, gx2, 200);
            window.postSyntheticMouse(.moved, gx2 - 40, 200);
            window.postSyntheticMouse(.left_up, gx2 - 40, 200);
        }
        if (smoke and spins == 797) divfile_dock_w_after = geom.dock.w;
        // ── 파일을 보는 중에 ＋ 를 누르면 (적대적 검증 1회차) ──────────────────────────
        //
        // 그 자리 주석이 이미 규칙을 적어 뒀다 — *"만들고 안 보여 주면 눌린 것이 화면에 안
        // 나타난다."* 그런데 파일이 활성이면 `selectTab` 만 하고 화면은 파일 그대로였다.
        // ── 범위를 넘긴 위치는 다음 프레임에 되돌아온다 (적대적 검증 2회차) ─────────────
        if (smoke and spins == 799) if (active_view == .file) {
            oob_judgeable = true;
            open_files.items[active_view.file].first_line = 1_000_000;
        };
        if (smoke and spins == 801) if (active_view == .file) {
            oob_first_after = open_files.items[active_view.file].first_line;
            oob_rows_after = editor_last_rows;
            oob_lines = open_files.items[active_view.file].lines.items.len;
        };
        if (smoke and spins == 800) if (app_window.active()) |a| {
            a.lockCore(io);
            mouse_sel_after = a.core.selectionViewportSpan() != null;
            a.unlockCore(io);
        };
        if (smoke and spins == 802) if (active_view == .file and sessions.items.len < max_win_sessions) {
            spawn_while_file_judgeable = true;
            spawn_while_file_sessions_before = sessions.items.len;
            const hcols2: u32 = sidebar_w / cell_w;
            const col2 = maru.chrome.components.sidebar.headerIconCol(.new_workspace, hcols2);
            const hx2: i32 = @intCast(col2 *| cell_w + cell_w / 2);
            const hy2: i32 = @intCast(geom.sidebar.y + sidebar_header_icon_band / 2);
            window.postSyntheticMouse(.moved, hx2, hy2);
            window.postSyntheticMouse(.left_down, hx2, hy2);
            window.postSyntheticMouse(.left_up, hx2, hy2);
        };
        if (smoke and spins == 808) {
            spawn_while_file_sessions_after = sessions.items.len;
            spawn_while_file_shows_terminal = active_view == .terminal;
        }
        // **새로고침을 누른다.** 헤더 전체가 refresh action 이고 정렬 토글이 그 오른쪽 끝을 파낸
        // 형태라(`build.zig` 의 그 주석), **왼쪽 4 분의 1** 을 겨눈다 — 가운데를 누르면 무엇을
        // 눌렀는지가 배치에 따라 흔들린다.
        // ── 훑는 중이라고 말하는가 (보고 결함 ③) ───────────────────────────────────────
        //
        // **목록이 그대로인 순간을 고른다.** 새로고침은 같은 이력을 다시 읽으므로 아이템이 안 바뀌고,
        // 그래서 화면이 달라진다면 그것은 **"분석 중" 문구와 죽은 아이콘**뿐이다 — 아이템 변화에
        // 묻히지 않는 자리다.
        if (smoke and spins == 761 and dock_view == .agent_sessions) {
            notice_items_before = agent_items.items.len;
            notice_digest_idle = d3d11_cells.cellsDigest(dock_cells.items);
        }
        // **끝나면 내려야 한다** — 안 내리면 "분석 중" 이 영영 붙어 있고, 그것은 아무 정보도 없는
        // 표시가 된다. 목록이 온 뒤의 조용한 순간에 잰다.
        if (smoke and spins == 940) {
            notice_settled_judgeable = agent_items.items.len > 0;
            notice_still_busy = agent_opts.loading or agent_opts.refreshing;
        }
        if (smoke and spins == 763 and agent_opts.refreshing) {
            notice_judgeable = true;
            notice_items_during = agent_items.items.len;
            notice_digest_busy = d3d11_cells.cellsDigest(dock_cells.items);
        }
        if (smoke and spins == 762) if (agent_built) |*b| {
            const id = maru.chrome.components.session_dock.build.NodeIds.header;
            for (b.frame.tree.entries) |e| {
                if (e.id != id) continue;
                ag_refresh_judgeable = true;
                ag_refresh_applies_before = agent_applies;
                const rx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(e.rect.x + e.rect.width / 4)));
                const ry: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(e.rect.y + e.rect.height / 2)));
                window.postSyntheticMouse(.left_down, rx, ry);
                window.postSyntheticMouse(.left_up, rx, ry);
                break;
            }
        };
        // **카드 위로 커서를 옮긴다** — 클릭이 아니라 이동만.
        if (smoke and spins == 745) if (agent_built) |*b| {
            for (agent_items.items, 0..) |it, idx| switch (it) {
                .card => {
                    if (agentItemRect(b, idx)) |r| {
                        ag_hover_judgeable = true;
                        ag_hover_redraws_before = agent_redraws;
                        ag_hover_intents_before = agent_applied_intents;
                        const hx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                        const hy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                        window.postSyntheticMouse(.moved, hx, hy);
                    }
                    break;
                },
                else => {},
            };
        };
        if (smoke and spins == 748) {
            ag_hover_redraws_after = agent_redraws;
            ag_hover_intents_after = agent_applied_intents;
        }
        if (smoke and spins == 713) ag_expand_before = agent_state.expanded_identity;
        // **카드부터 누른다** — 그룹을 접으면 그 카드들이 목록에서 빠져 누를 것이 없어진다.
        if (smoke and spins == 714) if (agent_built) |*b| {
            for (agent_items.items, 0..) |it, idx| switch (it) {
                .card => {
                    if (agentItemRect(b, idx)) |r| {
                        const cx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                        const cy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                        window.postSyntheticMouse(.left_down, cx, cy);
                        window.postSyntheticMouse(.left_up, cx, cy);
                    }
                    break;
                },
                else => {},
            };
        };
        if (smoke and spins == 715) ag_expand_target = agent_state.expanded_identity;
        if (smoke and spins == 716) if (agent_built) |*b| {
            // 첫 그룹 헤더의 자리를 published tree 에서 얻는다 — 손으로 고른 좌표면 배치가 바뀌어도
            // 판정이 안 움직인다.
            // 첫 그룹은 목록의 0 번이다(투영이 그룹 헤더를 먼저 낸다).
            if (agentItemRect(b, 0)) |r| {
                ag_click_judgeable = true;
                ag_items_before = agent_items.items.len;
                // **카드 클릭은 이 앞(714)에 이미 났다** — 그 결과를 여기서 기준으로 잡는다.

                const gx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                const gy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                window.postSyntheticMouse(.left_down, gx, gy);
                window.postSyntheticMouse(.left_up, gx, gy);
            }
        };
        // **같은 그룹을 다시 누른다** — 목록이 원래 길이로 돌아와야 한다.
        if (smoke and spins == 722) if (agent_built) |*b| {
            if (agentItemRect(b, 0)) |r| {
                const gx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                const gy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                window.postSyntheticMouse(.left_down, gx, gy);
                window.postSyntheticMouse(.left_up, gx, gy);
            }
        };
        // 그룹 0 과 1 을 **스핀을 갈라** 접는다. 한 스핀에 둘을 보내면 둘째 클릭이 **옛 프레임의
        // 자리와 action** 을 겨눈다 — 중립 `ids.Table.resolve` 가 세대로 그것을 거부하므로(그 규율이
        // 맞다) 접히는 것은 하나뿐이었다(실측 2026-08-27: `multi=1->2`).
        if (smoke and spins == 728) if (agent_built) |*b| {
            if (agentFirstGroupIndexAtOrAfter(agent_items.items, 0)) |idx| {
                if (agentItemRect(b, idx)) |r| {
                    const gx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                    const gy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                    window.postSyntheticMouse(.left_down, gx, gy);
                    window.postSyntheticMouse(.left_up, gx, gy);
                }
            }
        };
        if (smoke and spins == 733) if (agent_built) |*b| {
            if (agentFirstGroupIndexAtOrAfter(agent_items.items, 1)) |idx| {
                if (agentItemRect(b, idx)) |r| {
                    const gx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                    const gy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                    window.postSyntheticMouse(.left_down, gx, gy);
                    window.postSyntheticMouse(.left_up, gx, gy);
                }
            }
        };
        if (smoke and spins == 736) ag_multi_keys_before = agent_archive.collapsed.items.len;
        // **둘째 그룹만 다시 편다.** 첫째는 접힌 채 남아야 한다.
        if (smoke and spins == 738) if (agent_built) |*b| {
            if (agentFirstGroupIndexAtOrAfter(agent_items.items, 1)) |idx| {
                if (agentItemRect(b, idx)) |r| {
                    ag_multi_judgeable = true;
                    const gx: i32 = @intCast(geom.tree_content.x + @as(u32, @intFromFloat(r.x + r.width / 2)));
                    const gy: i32 = @intCast(geom.tree_content.y + @as(u32, @intFromFloat(r.y + r.height / 2)));
                    window.postSyntheticMouse(.left_down, gx, gy);
                    window.postSyntheticMouse(.left_up, gx, gy);
                }
            }
        };
        if (smoke and spins == 742) {
            ag_multi_keys_after = agent_archive.collapsed.items.len;
            // 첫째 그룹이 **여전히 접혀 있는가** — 그 자리의 항목이 group 이고 `collapsed` 여야 한다.
            if (agentFirstGroupIndexAtOrAfter(agent_items.items, 0)) |idx| {
                ag_multi_first_still = switch (agent_items.items[idx]) {
                    .group => |g| g.collapsed,
                    else => false,
                };
            }
        }
        if (smoke and spins == 725) {
            ag_items_reopened = agent_items.items.len;
            // 접기→펴기를 지난 뒤에도 같은 레코드가 펼쳐져 있는가.
            ag_expand_survived = agent_state.expanded_identity != null and
                agent_state.expanded_identity.? == (ag_expand_target orelse ~@as(u64, 0));
            ag_collapsed_reopened = agent_archive.collapsed.items.len;
        }
        if (smoke and spins == 719) {
            ag_items_after = agent_items.items.len;
            // 접은 그룹의 키를 알고 있으므로, 남은 카드의 레코드가 그 키를 안 갖는지 본다.
            if (agent_archive.collapsed.items.len == 1) {
                const gone = agent_archive.collapsed.items[0];
                for (agent_items.items) |it| switch (it) {
                    .card => |c| {
                        ag_kept_cards += 1;
                        if (c.identity < agent_archive.view_items.len) {
                            const vi = agent_archive.view_items[c.identity];
                            const key = if (vi.cwd_canonical and vi.cwd.len > 0) vi.cwd else "";
                            if (std.mem.eql(u8, key, gone)) ag_wrong_cards += 1;
                        }
                    },
                    else => {},
                };
            }
            ag_collapsed_after = agent_archive.collapsed.items.len;
            ag_expand_after = agent_state.expanded_identity;
        }
        if (smoke and spins == 646) {
            after_release_after = sidebar_scroll_px;
            after_release_dock_after = dock_scroll_px;
            // 이 순간 offset 이 **최대**다(위 끌기가 끝까지 갔다) — 그때 thumb 바닥과 트랙 바닥의
            // 차이를 잰다.
            if (sidebar_bar) |b| {
                bottom_gap = (b.track_y + b.track_h) - (b.thumb_y + b.thumb_h);
                bar_max = b.max_offset_px;
                const rr3 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
                const mm3 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
                // **휠이 쓰는 그 식 그대로**(그 자리의 주석: "상한은 콘텐츠가 정한다").
                wheel_max = maru.chrome.components.sidebar.contentHeight(rr3, mm3) -| (geom.sidebar.h -| sidebar_header_h);
                max_judgeable = true;
            }
        }
        // **여기가 그 순간이다** — 아래 스크롤바 시험이 값을 덮기 직전에 챙긴다.
        if (smoke and spins == 638 and !snap_taken) {
            snap_taken = true;
            snap_scroll_px = sidebar_scroll_px;
            snap_first_visible = sidebar_first_visible;
            snap_first_band_y = sidebar_first_band_y;
            snap_partial = sidebar_partial;
            snap_active_band_y = sidebar_active_band_y;
            snap_cards_visible = sidebar_cards_visible;
            snap_over_header = sidebar_card_over_header;
            // **원하는 자리도 이 순간에 계산한다.** 예전에는 끝 상태의 카드 목록으로 다시 계산했다 —
            // 638 이후에 목록이 안 바뀌던 동안만 우연히 맞았고, W8.13 이 그 뒤에 파일 카드를 붙이자
            // 곧바로 어긋났다(실측 `active_ok=false`). 판정은 **자기 순간**을 챙겨야 한다.
            const rr0 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm0 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            snap_content_h = maru.chrome.components.sidebar.contentHeight(rr0, mm0);
            snap_view_h = geom.sidebar.h -| sidebar_header_h;
            snap_want_band_y = @as(i64, geom.sidebar.y) +
                maru.chrome.components.sidebar.rowTop(rr0, sidebar_first_visible, sidebar_header_h, mm0, sidebar_scroll_px);
            snap_active_slot = sidebarActiveSlot(sidebar_cards.items, active_view);
            // **동어반복을 끊는다.** 그린 슬롯과 기대 슬롯이 같은 함수에서 나오면, 그 함수가 틀려도
            // 둘이 똑같이 틀려 판정이 맞다고 한다. 그래서 **그 칸의 이름이 지금 보고 있는 것을
            // 가리키는지**를 모델 쪽에서 따로 확인한다.
            snap_active_names_view = blk: {
                if (snap_active_slot >= sidebar_cards.items.len) break :blk false;
                const card_name = sidebar_cards.items[snap_active_slot].name;
                break :blk switch (active_view) {
                    .terminal => |t| t < sessions.items.len and std.mem.eql(u8, card_name, sessions.items[t].label()),
                    .file => |f| f < open_files.items.len and std.mem.eql(u8, card_name, open_files.items[f].name()),
                };
            };
            snap_want_active_y = @as(i64, geom.sidebar.y) +
                maru.chrome.components.sidebar.rowTop(rr0, snap_active_slot, sidebar_header_h, mm0, sidebar_scroll_px);
        }
        // ── 스크롤바 끌기 판정 (W8.10) ─────────────────────────────────────────────────
        //
        // **다른 판정이 다 끝난 뒤(635 이후)에 둔다.** 이 단계들은 스크롤 위치와 도크 뷰를 바꾸는데
        // 앞선 판정 둘이 그 값을 **끝 상태에서** 읽는다 — 가운데 끼웠더니 사이드바 스크롤과 세션
        // 전환이 둘 다 빨개졌다(실측 2026-08-26). 같은 변수를 덮는 이 함정은 이 포트에서 **네 번째**다.
        //
        // **thumb 을 잡아 아래로 끈다.** 휠과 달리 이 경로는 `offsetForPointer` 를 지나므로, 막대가
        // 죽어 있으면(그려만 지고 안 잡히면) offset 이 그대로다 — 그것이 이 판정의 전부다.
        // **먼저 맨 위로 되돌린다.** W8.18a 가 활성 카드를 보여 주려 목록을 **바닥까지** 굴려 놓아,
        // 여기서 아래로 끄는 이 시험이 "이미 끝이라 안 움직인다" 로 읽혔다(실측 `off 330->330`).
        // 시험은 자기가 재는 방향의 여지를 자기가 만든다.
        if (smoke and spins == 639) {
            const ux0: i32 = @intCast(geom.sidebar.x + geom.sidebar.w / 2);
            const uy0: i32 = @intCast(geom.sidebar.y + geom.sidebar.h / 2);
            var up_n: usize = 0;
            while (up_n < 12) : (up_n += 1) window.postSyntheticMouseWheel(.wheel, ux0, uy0, 3);
        }
        if (smoke and spins == 640) {
            if (sidebar_bar) |b| {
                sb_bar_seen = b;
                sb_bar_judgeable = true;
                sb_off_before = sidebar_scroll_px;
                const gx: i32 = @intFromFloat(b.hit_x + b.hit_w / 2);
                const gy: i32 = @intFromFloat(b.thumb_y + b.thumb_h / 2);
                window.postSyntheticMouse(.left_down, gx, gy);
                window.postSyntheticMouse(.moved, gx, gy + @as(i32, @intFromFloat(b.track_h / 2)));
                window.postSyntheticMouse(.left_up, gx, gy + @as(i32, @intFromFloat(b.track_h / 2)));
            }
        }
        if (smoke and spins == 643) sb_off_after = sidebar_scroll_px;
        // **트랙을 누른다 — 그리고 거터 맨 왼쪽에서.**
        //
        // 두 가지를 한 번에 잰다. ⑴ thumb 바깥을 누르면 그 자리로 뛰는가(`offsetForTrackClick`).
        // ⑵ **잡는 폭이 그리는 폭보다 넓은가** — `hit_x + 1` 은 거터 안이지만 막대(8px) **밖**이라,
        //    잡는 자리를 `track_w` 로 좁히면 이 클릭이 그냥 목록으로 샌다. 앞선 끌기 판정은 막대
        //    한가운데를 눌러서 그 차이를 **못 봤다**.
        if (smoke and spins == 648) if (sidebar_bar) |b| {
            sb_track_before = sidebar_scroll_px;
            const tx: i32 = @intFromFloat(b.hit_x + 1);
            const ty: i32 = @intFromFloat(b.track_y + 4);
            window.postSyntheticMouse(.left_down, tx, ty);
            window.postSyntheticMouse(.left_up, tx, ty);
            sb_track_judgeable = true;
        };
        if (smoke and spins == 651) sb_track_after = sidebar_scroll_px;
        // **합성된 셀에서 직접 찾는다** — 기하가 아니라 화면에 들어간 것을 본다. 그리기를 빼면
        // 이 값이 죽는다(기하 판정은 안 죽는다).
        // **지금 프레임의 막대**를 본다 — 끌기 전에 잡아 둔 것과 견주면 thumb 이 그 사이 움직여
        // "안 그려졌다" 가 된다(실측: `drawn=false` 가 그 이유였다).
        if (smoke and spins == 644) if (sidebar_bar) |b| {
            for (cells.items) |c| {
                if (@abs(c.rect[0] - b.track_x) < 0.5 and @abs(c.rect[2] - b.track_w) < 0.5 and
                    @abs(c.rect[1] - b.thumb_y) < 0.5 and @abs(c.rect[3] - b.thumb_h) < 0.5) sb_bar_drawn = true;
                // **글자가 막대 자리에 있으면 안 된다.** 거터를 안 비우면 카드 이름 끝이 막대 밑으로
                // 들어간다 — 중립이 "겹쳐 그리는 대안은 사용자가 겹쳐 보인다고 보고한 그 상태" 라고
                // 적어 둔 자리다. 배경 쿼드(uv 0)는 빼고 **글리프만** 센다.
                // **단색 셀은 음수 UV 다**(`d3d11_cells.solidCell` — 셰이더가 그것으로 가른다).
                // `uv[2] != 0` 로 보면 배경·밴드·막대 자신이 전부 "글자" 로 세어진다(실측: 겹침이
                // 4 로 나왔는데 넷 다 쿼드였다).
                const is_glyph = c.uv[0] >= 0;
                if (is_glyph and c.rect[0] + c.rect[2] > b.track_x and c.rect[0] < b.track_x + b.track_w and
                    c.rect[1] + c.rect[3] > b.track_y and c.rect[1] < b.track_y + b.track_h)
                {
                    sb_bar_overlap += 1;
                }
            }
        };
        if (smoke and spins == 590 and sidebar_header_h != 0) {
            const rr = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            // **넘치는가로 가른다** — 카드 수가 아니라(도크에서 그 가드를 틀렸다).
            if (maru.chrome.components.sidebar.contentHeight(rr, mm) > geom.sidebar.h -| sidebar_header_h) {
                sidebar_scroll_judgeable = true;
                const sx: i32 = @intCast(sidebar_w / 2);
                const sy: i32 = @intCast(geom.sidebar.y + sidebar_header_h + 20);
                window.postSyntheticMouseWheel(.wheel, sx, sy, -1);
            }
        }
        if (smoke and spins == 620 and sidebar_scroll_judgeable) {
            // **그린 밴드 한복판을 누른다.** 헤더 바로 아래(목록 위 여백)를 누르면 `slotAt` 이 그
            // 여백을 **이전 카드**로 되돌린다 — 그 자리는 카드가 그려진 자리가 아니다(실측:
            // `first_visible=1` 인데 `clicked_slot=0` 이었다).
            const sx: i32 = @intCast(sidebar_w / 2);
            // **보이는 부분을 누른다.** 스크롤로 첫 카드 위가 헤더에 가리면 그 위를 눌러야 소용없다.
            const visible_top = @max(sidebar_first_band_y, geom.sidebar.y + sidebar_header_h);
            const sy: i32 = @intCast(visible_top + cell_h / 2);
            sidebar_slot_before_scroll_click = sidebar_last_slot;
            window.postSyntheticMouse(.left_down, sx, sy);
            window.postSyntheticMouse(.left_up, sx, sy);
            sidebar_scroll_click_sent = true;
        }
        // **활성을 첫 보이는 카드와 다른 카드로 옮긴다.** 둘이 같으면 "앰버 막대가 옳은 카드에
        // 있나" 를 물어도 구별이 안 된다 — 그 상태에서 뮤턴트 둘이 그대로 통과했다.
        // **첫 클릭의 답을 먼저 챙긴다** — 아래 두 번째 클릭이 같은 변수를 덮는다.
        if (smoke and spins == 630 and sidebar_scroll_click_sent) {
            sidebar_scroll_clicked_slot = sidebar_last_slot;
            sidebar_last_slot = sidebar_slot_before_scroll_click;
        }
        if (smoke and spins == 635 and sidebar_scroll_judgeable and sidebar_cards_visible > 1) {
            const sx2: i32 = @intCast(sidebar_w / 2);
            const rr3 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm3 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const second_top: i64 = @as(i64, geom.sidebar.y) +
                maru.chrome.components.sidebar.rowTop(rr3, sidebar_first_visible + 1, sidebar_header_h, mm3, sidebar_scroll_px);
            if (second_top > 0) {
                const sy2: i32 = @intCast(second_top + @as(i64, cell_h));
                window.postSyntheticMouse(.left_down, sx2, sy2);
                window.postSyntheticMouse(.left_up, sx2, sy2);
            }
        }

        if (smoke and spins == 530 and sessions.items.len > 1) {
            switch_judgeable = true;
            grid_digest_before_switch = activeGridDigest(io, &app_window);
            active_before_switch = app_window.active_tab;
            const rws = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const m_sw = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            const y0 = maru.chrome.components.sidebar.rowTop(rws, 0, sidebar_header_h, m_sw, 0);
            const cy: i32 = @intCast(geom.sidebar.y + @as(u32, @intCast(@max(0, y0))) + cell_h);
            const cx: i32 = @intCast(sidebar_w / 2);
            window.postSyntheticMouse(.moved, cx, cy);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
        }
        // ── 세션이 둘일 때 창 크기를 바꾼다 (W8.8⒞) ────────────────────────────────────────
        //
        // **이것이 없으면 `sessions_wrong_size` 가 못 잰다.** 위 캡션 판정의 리사이즈는 전부
        // spawn **앞**에서 일어나므로, 배경 세션만 옛 격자로 남는 실패를 밟을 자리가 없다
        // (실측: 활성만 리사이즈하는 뮤턴트가 그 상태에서 살아남았다).
        // **되돌아오지 않는 리사이즈여야 한다.** 최대화→복원 왕복은 크기가 제자리로 와서 배경
        // 세션이 뒤처진 것을 덮는다(실측: 왕복으로는 뮤턴트가 살아남았다). 디바이더를 끌면
        // 터미널 격자가 **그대로 좁아진 채** 남는다.
        if (smoke and spins == 600 and sessions.items.len > 1 and geom.divider.w != 0) {
            const gx: i32 = @intCast(geom.divider.x + geom.divider.w / 2);
            window.postSyntheticMouse(.left_down, gx, 300);
            window.postSyntheticMouse(.moved, gx - 60, 300);
            window.postSyntheticMouse(.left_up, gx - 60, 300);
        }
        if (smoke and spins == 560 and switch_judgeable) {
            grid_digest_after_switch = activeGridDigest(io, &app_window);
            // **시간 비교는 혼입된다** — 셸이 계속 출력하므로 전환을 안 해도 지문이 바뀐다(실측:
            // `selectTab` 을 막은 뮤턴트에서도 `grid_changed=true` 였다). 그래서 **활성 화면이
            // 지금 어느 세션의 것인가**를 직접 본다: 활성 지문이 그 세션 것과 같고 **다른 세션과는
            // 다른가**.
            const sel = surfaceGridStats(io, &sessions.items[app_window.active_tab].surface);
            const other_idx: usize = if (app_window.active_tab == 0) 1 else 0;
            const other = surfaceGridStats(io, &sessions.items[other_idx].surface);
            active_matches_selected = grid_digest_after_switch == sel.digest and sel.digest != other.digest;
            // **배경 세션 화면이 살아 있는가.** 잉크 셀이 있으면 그 세션의 셸 출력이 코어에
            // 적용된 것이다 — 리더 스레드가 한 일이다(pump 가 아니다, 위 주석).
            background_ink = other.ink;
        }
        if (smoke and spins == 450 and titlebar_px != 0) {
            frameless_covers = window.clientCoversWindow();
            const wr = window.windowRect();
            const border: i32 = 8; // 모서리 규칙에 안 걸리게 충분히 안쪽에서 찌른다
            // 띠의 **빈 곳**(왼쪽) → 캡션, 캡션 **버튼 자리** → 클라이언트, 띠 **아래** → 클라이언트.
            const mid_x: i32 = wr.left + @divTrunc(@as(i32, @intCast(client_w)), 2);
            nchittest_strip = window.probeHitTest(mid_x, wr.top + border + 4);
            nchittest_button = window.probeHitTest(wr.right - 10, wr.top + border + 4);
            nchittest_below = window.probeHitTest(mid_x, wr.top + @as(i32, @intCast(titlebar_px)) + 20);
            // **띠 안의 사이드바 폭**은 우리 몫이어야 한다 — 헤더 아이콘 줄이 거기 있다. 순수
            // 테스트는 함수만 재고 **배선은 안 잰다**(그 doc 이 적어 둔 실패), 그래서 진짜 wndproc 에
            // 묻는다. 실제로 그려진 아이콘 하나(＋)의 col 을 쓴다 — 손으로 고른 좌표면 아이콘이
            // 옮겨가도 판정이 안 움직인다.
            if (sidebar_w != 0 and cell_w != 0) {
                const icol = maru.chrome.components.sidebar.headerIconCol(.new_workspace, sidebar_w / cell_w);
                nchittest_sidebar_icon = window.probeHitTest(wr.left + @as(i32, @intCast(icol *| cell_w + cell_w / 2)), wr.top + border + 4);
            }
        }
        if (smoke and spins == 120) {
            selections_before_term_click = selections;
            dock_clicks_before_term_click = dock_row_clicks;
            const tx: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const ty: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            window.postSyntheticMouse(.left_down, tx, ty);
            window.postSyntheticMouse(.left_up, tx, ty);
        }
        // ── 스캔 결과 받기 (W8.12) ──────────────────────────────────────────────────────
        //
        // **매 프레임 받는다.** 예전에는 토글한 자리에서 400 회까지 `sleep(1ms)` 로 기다렸고 그동안
        // 창이 통째로 멈췄다 — 이제 제출만 하고 여기서 받는다. 결과가 없으면 이 줄은 공짜다.
        // 이력 결과도 매 프레임 받는다. 안 왔으면 `null` 이고 이 줄은 공짜다.
        if (agent_backend) |*b| {
            if (drainAgentItems(agent_counting.allocator(), agent_arena.allocator(), io, b, &agent_archive, &agent_items, &agent_scan_finished, &agent_scan_partial)) |reason| {
                agent_list_reason = reason;
                agent_scan_kb = agent_counting.peak / 1024;
                agent_applies += 1;
                if (agent_apply_spin == null) agent_apply_spin = frames_total;
                // **옵션도 새 목록을 봐야 한다** — 슬라이스를 안 갱신하면 빈 목록이 그대로 남는다.
                agent_opts.items = agent_items.items;
                agent_opts.sort_order = agent_archive.sort;
                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
            }
        }
        // 이력이 아직 안 왔고 올 가능성이 있으면 단계 번호를 멈춰 세운다 — 상한을 둔다(이력이
        // 없는 기계에서 영영 안 오면 스모크가 통째로 멈춘다).
        // 첫 훑기든 새로고침이든 **결과를 기다리는 동안**은 번호를 멈춰 세운다. 새로고침을 안 세우면
        // 다음 단계가 옛 목록을 재고, 캐시가 더운 기계에서만 초록인 판정이 된다.
        const waiting_first = agent_apply_spin == null;
        const waiting_refresh = agent_refresh_submits > 0 and agent_applies <= ag_refresh_applies_before;
        agent_settling = smoke and agent_backend != null and settle_frames < 6000 and (waiting_first or waiting_refresh);
        if (drainTreeScan(allocator, io, &dock_tree, if (tree_backend) |*b| b else null, &dock_rows, dock_root orelse ".")) {
            tree_scan_applied += 1;
            if (tree_expand_submit_spin != null and tree_expand_apply_spin == null) tree_expand_apply_spin = spins;
            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
        }
        for (window.poll()) |ev| switch (ev) {
            .resized => |r| {
                try present.resize(r.width_px, r.height_px);
                // **기하를 먼저 다시 잰다** — 도크 폭이 창 크기에 따라 달라지므로 터미널 사각형도 바뀐다.
                client_w = r.width_px;
                client_h = r.height_px;
                geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px, status_bar_px);
                rebuildStatusBar(allocator, &status_cells, geom.status_bar, cell_w, cell_h, &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &status_uploads, status_items, &status_frames, &status_dropped, &status_placed, &status_outside, &status_mismatch, &status_rebuilds);
                // **터미널 격자도 바꾼다.** 스왑체인만 맞추면 셸이 옛 크기로 계속 출력해 줄이 어긋난다.
                if (win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h)) |size| {
                    resizeAllSessions(&runtime, sessions.items, size, io);
                    // **리사이즈도 판정한다.** 여기가 없으면 불변식이 **첫 프레임에서만** 지켜진다 —
                    // `resizeActiveSurface` 가 실패하면(위 `catch {}`) 기하는 바뀌었는데 코어는 옛
                    // 격자로 남고, 화면은 그럴듯한 채로 셸의 줄바꿈만 어긋난다.
                    resizes += 1;
                    // **방금 넘긴 값과 견주면 안 된다** — 그건 언제나 같아서 아무것도 안 잰다
                    // (실측: 리사이즈 격자를 창에서 유도하는 뮤턴트가 `grid_mismatches=0` 으로
                    // 통과했다. 화면 숫자는 153x34 로 틀렸는데도). **사각형에서 독립으로** 다시
                    // 뽑아 견준다.
                    if (app_window.active()) |a| {
                        const want_now = win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h) orelse
                            maru.terminal.Size{ .cols = 0, .rows = 0 };
                        if (a.core.size.cols != want_now.cols or a.core.size.rows != want_now.rows) grid_mismatches += 1;
                    }
                }
                // **여기 실패는 세어서 보고한다.** 삼키면 도크 배경이 옛 자리에 남는다.
                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {
                    dock_rebuild_failures += 1;
                };
                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                rebuildTitlebarCells(allocator, &titlebar_cells, client_w, sidebar_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens) catch {};
            },
            .paint => {},
            .close_requested => close_requested = true,
            // **입력이 여기서 셸로 간다.** 창은 중립 `KeyEvent`만 주고, 앱 동작이냐 셸 입력이냐는
            // `handleKeyEvent`(중립 정책)가 정한다 — Windows 가 키바인딩을 다시 발명하지 않는다.
            .key => |key_ev| {
                // ── 파일을 보는 중에는 키가 셸로 안 간다 (적대적 검증 2회차) ──────────────
                //
                // **화면에 문서가 떠 있는데 친 글자가 안 보이는 셸로 들어가면 안 된다.** 사용자는
                // 자기가 무엇을 치고 있는지 모른 채 치게 되고, 개행 하나면 그것이 **실행**된다.
                // 실측으로 그랬다(`reached_terminal=1`).
                //
                // **복사·붙여넣기도 함께 막는다** — 복사는 안 보이는 터미널의 선택을 집어 오고,
                // 붙여넣기는 안 보이는 셸에 쏟는다. 지금 이 뷰는 읽기 전용이라 삼키는 것이 맞다.
                // ── 모달이 열려 있으면 키는 모달 것이다 (W8.16b) ──────────────────────
                //
                // **모든 것보다 먼저다.** 모달은 화면을 덮고 있으므로 그 뒤로 키가 새면 사용자는
                // 보이지 않는 곳을 조작하게 된다. 판정은 중립이 소유한다(`confirm.handle`:
                // Enter/Esc·Y/N·←/→).
                if (confirm_state.open) {
                    if (maru.chrome.components.confirm.handle(win32_keys.chromeKeyEvent(key_ev), &confirm_state)) |action| switch (action) {
                        .confirmed => {
                            confirm_accepts += 1;
                            confirm_state.dismiss();
                            // **지금 다시 푼다** — 담아 둔 번호가 그 사이 밀렸을 수 있다.
                            if (sessionIndexById(sessions.items, pending_close_id)) |ci| {
                                switch (closeWinSession(allocator, io, &sessions, &tab_ptrs, &app_window, &runtime, ci, true)) {
                                    .closed => {
                                        session_closes += 1;
                                        pump = sessions.items[0].pump;
                                        if (active_view == .terminal) active_view = .{ .terminal = app_window.active_tab };
                                        refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                                        sidebar_redraws += 1;
                                        rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                    },
                                    else => {},
                                }
                            }
                            pending_close_id = null;
                        },
                        .cancelled => {
                            confirm_cancels += 1;
                            confirm_state.dismiss();
                            pending_close_id = null;
                        },
                        .alternate => {},
                    };
                    continue;
                }
                // ── 검색이 포커스면 키는 검색 것이다 (W8.15) ─────────────────────────
                //
                // **파일 삼킴보다 먼저 본다.** 뒤에 두면 문서를 보는 중에는 검색에 글자를 못 친다.
                if (search_focused) {
                    var changed_q = false;
                    switch (key_ev.key) {
                        .escape => {
                            search_focused = false;
                            search_focus_changes += 1;
                            changed_q = true;
                        },
                        .backspace => {
                            search.backspace();
                            changed_q = true;
                        },
                        // **글자만 받는다.** 기능 키·화살표는 검색어가 아니다 — 중립 `Key` 가
                        // 그것을 이미 갈라 두었으므로 여기서 코드포인트 범위로 다시 판정하지 않는다.
                        .char => |cp| {
                            if (cp >= 0x20) {
                                search.appendChar(allocator, cp) catch {};
                                search_chars += 1;
                                changed_q = true;
                            }
                        },
                        else => {},
                    }
                    if (changed_q) {
                        refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                        sidebar_redraws += 1;
                        rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                    }
                    continue;
                }
                // 에이전트 도크 검색도 같은 축이다 — 그 뷰가 보일 때만 받는다.
                if (agent_search_focused and dock_view == .agent_sessions) {
                    var changed_a = false;
                    switch (key_ev.key) {
                        .escape => {
                            agent_search_focused = false;
                            agent_search_focus_changes += 1;
                            changed_a = true;
                        },
                        .backspace => {
                            agent_search.backspace();
                            changed_a = true;
                        },
                        .char => |cp| {
                            if (cp >= 0x20) {
                                agent_search.appendChar(allocator, cp) catch {};
                                agent_search_chars += 1;
                                changed_a = true;
                            }
                        },
                        else => {},
                    }
                    if (changed_a) {
                        agent_archive.query = agent_search.query.items;
                        var qa = std.heap.ArenaAllocator.init(allocator);
                        defer qa.deinit();
                        projectAgentItems(qa.allocator(), agent_arena.allocator(), &agent_archive, &agent_items) catch {};
                        agent_opts.items = agent_items.items;
                        agent_opts.search = agent_search.query.items;
                        agent_opts.search_focused = agent_search_focused;
                        agent_state.invalidateTree();
                        rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                        agent_redraws += 1;
                    }
                    continue;
                }
                if (active_view == .file) {
                    keys_while_file += 1;
                    continue;
                }
                // **복사가 여기서 붙는다.** §2j 가 `isCopyChord` 를 만들어 두고 호출자를 못 붙인 것은
                // "무엇을 복사할지"가 선택 영역이고 그것이 마우스와 같은 계층이었기 때문이다(§2k).
                // 경계는 그대로다 — 선택은 중립 코어가, 클립보드는 플랫폼이 안다.
                if (win32_keys.isCopyChord(key_ev)) {
                    const active = app_window.active() orelse continue;
                    // 추출은 **락 아래**(코어 읽기), OS 호출은 락 밖 — §2j 의 규율 그대로다.
                    const maybe_text: ?[]u8 = blk: {
                        active.lockCore(io);
                        defer active.unlockCore(io);
                        break :blk active.core.extractSelection(allocator) catch null;
                    };
                    if (maybe_text) |text| {
                        defer allocator.free(text);
                        if (text.len > 0) {
                            if (win32_clipboard.write(allocator, window.hwnd, text)) |_| {
                                copies += 1;
                                copy_bytes += text.len;
                            } else |err| {
                                try stderr.print("  warning: copy failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
                                clipboard_errors += 1;
                            }
                        }
                    }
                    continue;
                }
                // **붙여넣기는 플랫폼이 가로챈다.** 클립보드는 OS 소유이고 중립 레이어에 `Action`이 없다
                // (`config/action.zig` 경계: Zig 는 selection, 플랫폼은 clipboard) — macOS 가 Swift 쪽에서
                // 하는 것과 같은 자리다. `Ctrl+Shift+V`(Windows Terminal 관례)와 `Shift+Insert`(고전 관례)
                // 둘 다 받는다.
                if (win32_keys.isPasteChord(key_ev)) {
                    try pasteClipboardIntoActive(allocator, io, window.hwnd, &app_window, &runtime, stderr, paste_protection, bracketed_paste_is_safe, &paste_out);
                    continue;
                }
                // **`option_as_meta` 를 config 에서 넘긴다.** 세 번째 인자가 그것인데 리터럴 `false` 를
                // 넘기고 있었다 — 스키마 기본값은 `true` 다. 그 상태로는 `translateModifiers` 가 Alt+B 에
                // `.option = true` 를 옳게 세워도 `encodeKey` 의 가드가 꺼져 ESC 접두가 안 붙고,
                // readline 의 단어 이동(Alt+B/F/.)이 글자 `b` 를 그냥 찍는다.
                const outcome = loop.handleKeyEvent(resolver, key_ev, option_as_meta, null) catch |err| {
                    try stderr.print("  warning: key handling failed({s})\n", .{@errorName(err)});
                    continue;
                };
                switch (outcome) {
                    .terminal_input => |ti| {
                        keys_to_shell += 1;
                        bytes_to_shell += ti.bytes_len;
                        if (active_view == .file) keys_to_terminal_while_file += 1;
                    },
                    // 앱 동작은 아직 할 일이 없다(Windows 엔 탭·pane 이 없다 — W8). 센다.
                    .app_action => app_actions += 1,
                    .ignored => keys_ignored += 1,
                }
            },
            // IME 조합 미리보기. **중립 계약에 그대로 넣는다** — `renderSnapshot()`이 합성해 주므로
            // Windows 가 미리보기 렌더를 따로 만들지 않는다(§2i).
            .preedit_changed => {
                const text = window.preeditText();
                if (app_window.active()) |active| {
                    active.lockCore(io);
                    // 실패하면(OOM) fail-closed 로 비운다 — 그것이 중립 계약의 규약이다.
                    if (!active.setPreeditLocked(text)) preedit_failures += 1;
                    active.unlockCore(io);
                }
                preedit_updates += 1;
                if (text.len > preedit_max_bytes) preedit_max_bytes = text.len;
            },
            // **마우스는 중립 명령으로 번역만 한다**(§2k). 선택 코어 mutate 는 전부 `enqueueCoreCommand`
            // 로 리더 스레드에 위임한다 — 메인은 코어를 안 만진다.
            .mouse => |m| {
                const active = app_window.active() orelse continue;
                mouse_events += 1;

                // ── 캡션 버튼 (W8.8⒝) ──────────────────────────────────────────────────
                //
                // **띠 위는 영역 판정보다 먼저 본다.** 여기서 안 가로채면 캡션 버튼 클릭이
                // 터미널 선택이 된다.
                //
                // **다만 사이드바 폭은 뺀다.** 띠의 그 부분은 창 chrome 이 아니라 **사이드바 헤더의
                // 아이콘 줄**이다(`dock_layout.sidebarOf` 가 그렇게 정한다 — macOS 는 그 자리가
                // 신호등이고 Windows 는 캡션 버튼이 반대쪽이라 비어 있다). 안 빼면 아이콘이
                // 그려지는데 **안 눌린다**: 이 분기가 `continue` 로 삼켜 `regionAt` 까지 못 간다
                // (실측 2026-08-25: 띠를 합치자마자 `header_clicks` 가 4 → 0 이 됐다).
                if (titlebar_px != 0 and m.y_px >= 0 and m.y_px < @as(i32, @intCast(titlebar_px)) and
                    m.x_px >= @as(i32, @intCast(sidebar_w)))
                {
                    const rects = captionButtonRects(client_w, titlebar_px, caption_btn_w);
                    var hit: ?usize = null;
                    for (rects, 0..) |r, i| {
                        if (m.x_px >= @as(i32, @intCast(r.x)) and m.x_px < @as(i32, @intCast(r.x + r.w))) hit = i;
                    }
                    if (hit != caption_hover) {
                        caption_hover = hit;
                        rebuildTitlebarCells(allocator, &titlebar_cells, client_w, sidebar_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens) catch {};
                    }
                    if (m.kind == .left_up) if (hit) |i| {
                        caption_clicks += 1;
                        switch (i) {
                            0 => window.minimize(),
                            1 => window.toggleMaximize(),
                            else => close_requested = true,
                        }
                    };
                    continue;
                } else if (caption_hover != null) {
                    caption_hover = null;
                    rebuildTitlebarCells(allocator, &titlebar_cells, client_w, sidebar_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens) catch {};
                }

                // ── 스크롤바 (W8.10) ────────────────────────────────────────────────────
                //
                // **영역 판정보다 먼저 본다.** 거터는 도크/사이드바 사각형 **안**이라, 나중에 보면
                // 목록 행 클릭이 막대를 가져간다(중립 doc 이 "탐색기는 스크롤바를 행보다 먼저
                // 판정한다" 로 그 순서를 정해 뒀다).
                if (bar_drag) |drag| {
                    if (m.kind == .moved) {
                        const bar = if (drag.which == .dock) dock_bar else sidebar_bar;
                        if (bar) |b| {
                            const next = b.offsetForPointer(@floatFromInt(m.y_px), drag.grab_dy);
                            if (drag.which == .dock) {
                                if (next != dock_scroll_px) {
                                    dock_scroll_px = next;
                                    dock_scrolls += 1;
                                    bar_drag_moves += 1;
                                    rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                                }
                            } else if (next != sidebar_scroll_px) {
                                sidebar_scroll_px = next;
                                sidebar_scrolls += 1;
                                sidebar_redraws += 1;
                                bar_drag_moves += 1;
                                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                            }
                        }
                        continue;
                    }
                    if (m.kind == .left_up or m.kind == .capture_lost) {
                        bar_drag = null;
                        continue;
                    }
                }
                if (m.kind == .left_down) {
                    const py: f64 = @floatFromInt(m.y_px);
                    const on_dock = if (dock_bar) |b| barHit(b, m.x_px, m.y_px) else false;
                    const on_sidebar = if (!on_dock) (if (sidebar_bar) |b| barHit(b, m.x_px, m.y_px) else false) else false;
                    if (on_dock or on_sidebar) {
                        const b = (if (on_dock) dock_bar else sidebar_bar).?;
                        if (b.thumbContains(py)) {
                            bar_drag = .{ .which = if (on_dock) .dock else .sidebar, .grab_dy = @floatCast(py - @as(f64, b.thumb_y)) };
                        } else {
                            // **트랙을 누르면 그 자리로 간다** — 이어서 끌면 같은 매핑을 쓰므로
                            // 위치가 안 튄다(중립 `offsetForTrackClick` 의 계약).
                            const next = b.offsetForTrackClick(py);
                            bar_track_clicks += 1;
                            if (on_dock) {
                                dock_scroll_px = next;
                                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                            } else {
                                sidebar_scroll_px = next;
                                sidebar_redraws += 1;
                                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                            }
                            bar_drag = .{ .which = if (on_dock) .dock else .sidebar, .grab_dy = b.thumb_h / 2 };
                        }
                        continue;
                    }
                }

                // ── 어느 영역의 포인터인가 (W8.7b) ──────────────────────────────────────
                //
                // **판정은 중립이 소유한다**(`dock_layout.regionAt`) — 잡기 띠가 이웃과 겹치는
                // 규칙까지 거기 한 곳에 있다. 여기서 `x >= dock.x` 를 적으면 경계 한 픽셀이
                // macOS 와 갈린다.
                //
                // **드래그 중에는 안 가른다.** 터미널에서 시작한 선택이 도크 위를 지나갈 때
                // 영역이 바뀌면 그 순간 선택이 끊긴다 — 제스처는 시작한 곳이 끝까지 소유한다.
                // ── 디바이더 드래그 (W8.7c) ─────────────────────────────────────────────
                //
                // **영역 판정보다 먼저다.** 끌다 보면 포인터가 잡기 띠를 벗어나는데, 그때 영역으로
                // 다시 가르면 막대를 놓치고 터미널에 선택이 생긴다 — 제스처는 시작한 곳이 소유한다.
                if (divider_drag) |off| {
                    if (m.kind == .left_up or m.kind == .capture_lost) {
                        divider_drag = null;
                    } else if (m.kind == .moved) {
                        const cand = maru.session.dock_layout.sizePtForPointer(
                            geom,
                            .right,
                            @as(f64, @floatFromInt(m.x_px)) + off,
                            @floatFromInt(m.y_px),
                            1000,
                        );
                        if (cand) |pt| if (pt != dock_size_pt) {
                            dock_size_pt = pt;
                            geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px, status_bar_px);
                            rebuildStatusBar(allocator, &status_cells, geom.status_bar, cell_w, cell_h, &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &status_uploads, status_items, &status_frames, &status_dropped, &status_placed, &status_outside, &status_mismatch, &status_rebuilds);
                            // **화면에 선 크기를 도로 저장한다.** 포인터가 창 밖으로 나가면 `pt` 는
                            // 화면보다 훨씬 큰 값이 되는데(실측: `stored_pt=5979` 인데 `shown_w=654`),
                            // 그 상태로 창을 키우면 도크가 **새 공간을 통째로 먹는다**(실측: 654 →
                            // 1254px, 터미널이 35 열로 쪼그라들었다). macOS 가 같은 자리에서
                            // `sizePtForEffectiveWidth` 로 되쓰는 이유다.
                            dock_size_pt = maru.session.dock_layout.sizePtForEffectiveWidth(geom.dock_size_px, 0, 1000);
                            // **터미널 격자도 따라간다** — 창 크기가 바뀐 것과 같은 일이다.
                            if (win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h)) |size|
                                resizeAllSessions(&runtime, sessions.items, size, io);
                            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {
                                dock_rebuild_failures += 1;
                            };
                            divider_moves += 1;
                        };
                    }
                    continue;
                }

                const region = if (dragging)
                    maru.session.dock_layout.Region.terminal
                else
                    maru.session.dock_layout.regionAt(geom, @floatFromInt(m.x_px), @floatFromInt(m.y_px));
                if (region == .divider and m.kind == .left_down) {
                    divider_drag = maru.session.dock_layout.grabOffsetPx(geom, .right, @floatFromInt(m.x_px), @floatFromInt(m.y_px));
                    divider_grabs += 1;
                    continue;
                }
                // ── 사이드바: 헤더와 카드가 눌린다 (W8.8⒜3) ────────────────────────────
                //
                // **영역 판정도 그 안의 자리도 중립이 소유한다** — `dock_layout.regionAt` 이
                // "사이드바냐" 를, `chrome.components.sidebar` 의 `headerHit`·`slotAt` 이 "그 안
                // 어디냐" 를 가른다. 여기서 `x < sidebar_w` 를 손으로 적으면 경계 한 픽셀이
                // macOS 와 갈린다(도크·디바이더가 이미 겪은 실패다).
                //
                // **누르는 것과 지금 가리키는 것을 함께 갱신한다** — hover 가 안 바뀌면 눌러도
                // 화면이 그대로라 "죽은 컨트롤" 과 구별이 안 된다(§2m.35 가 그 실패를 겪었다).
                // ── 모달이 떠 있으면 버튼만 받고 나머지는 삼킨다 (W8.16b) ─────────────────
                //
                // **캡션 버튼 뒤에 둔다.** 앞에 두면 모달이 뜬 동안 창의 최소화·최대화·닫기까지
                // 죽어 사용자가 빠져나갈 길이 준다 — OS 창 조작은 앱 모달의 대상이 아니다
                // (적대적 검증 2회차 실측: `caption_alive=false`).
                if (confirm_state.open) {
                    if (m.kind == .left_up) {
                        if (maru.chrome.components.confirm.buttonAtPoint(&confirm_state, confirmProps(client_w, client_h, cell_w, cell_h, sidebar_w), &chrome_tokens, @floatFromInt(m.x_px), @floatFromInt(m.y_px))) |action| switch (action) {
                            .confirmed => confirm_pending_click = .confirmed,
                            .cancelled => confirm_pending_click = .cancelled,
                            .alternate => {},
                        };
                    }
                    continue;
                }
                if (region == .sidebar and m.kind == .wheel) {
                    // **헤더는 안 굴린다** — 고정이다(`slotAt` 이 정한 규칙). 목록만 움직인다.
                    const notches = wheel_acc_sidebar.feed(m.wheel_delta);
                    if (notches != 0 and sidebar_header_h != 0) {
                        const lines = win32_mouse.WheelAccumulator.linesForNotches(notches, wheel_lines_per_notch);
                        const rws2 = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
                        const m2 = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
                        // **상한은 콘텐츠가 정한다** — 중립이 그 높이를 소유한다(`contentHeight`).
                        const content_h = maru.chrome.components.sidebar.contentHeight(rws2, m2);
                        const view_h = geom.sidebar.h -| sidebar_header_h;
                        const max_scroll: u32 = content_h -| view_h;
                        const delta: i64 = @as(i64, lines) * @as(i64, @intCast(cell_h));
                        const next: i64 = @as(i64, sidebar_scroll_px) - delta;
                        const clamped: u32 = @intCast(std.math.clamp(next, 0, @as(i64, max_scroll)));
                        if (clamped != sidebar_scroll_px) {
                            sidebar_scroll_px = clamped;
                            sidebar_scrolls += 1;
                            sidebar_redraws += 1;
                            rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                        }
                    }
                    continue;
                }
                if (region == .sidebar and m.kind != .capture_lost) {
                    sidebar_pointer_events += 1;
                    const local_y: f64 = @floatFromInt(m.y_px - @as(i32, @intCast(geom.sidebar.y)));
                    const next_header: ?maru.chrome.components.sidebar.HeaderRegion = if (sidebar_header_h == 0) null else blk: {
                        const r = maru.chrome.components.sidebar.headerHit(
                            @floatFromInt(m.x_px),
                            local_y,
                            sidebar_w,
                            cell_w,
                            cell_h,
                            sidebar_header_h,
                            sidebar_header_icon_band,
                        );
                        break :blk if (r == .none) null else r;
                    };
                    // **그리는 쪽과 같은 행 목록을 쓴다** — 여기서 따로 만들면 카드 높이가 갈려
                    // 그린 자리와 눌리는 자리가 어긋난다.
                    const sb_rows = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
                    const next_slot = maru.chrome.components.sidebar.slotAt(
                        local_y,
                        sidebar_header_h,
                        sb_rows,
                        maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h),
                        sidebar_scroll_px,
                    );
                    if (next_header != sidebar_hover_header or next_slot != sidebar_hover_slot) {
                        sidebar_hover_header = next_header;
                        sidebar_hover_slot = next_slot;
                        sidebar_redraws += 1;
                        rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                    }
                    if (m.kind == .left_up) {
                        if (next_header) |r| {
                            sidebar_header_clicks += 1;
                            sidebar_last_header = r;
                            // ── ＋ 가 세션을 만든다 (W8.8⒞) ────────────────────────────
                            //
                            // **여기가 유일한 spawn 자리다.** 세션이 하나 늘면 카드 목록·탭
                            // 슬라이스를 함께 다시 만들어야 한다 — 안 그러면 사이드바가 옛
                            // 목록을 그리고 `slotAt` 이 없는 카드를 가리킨다.
                            //
                            // **실패해도 창은 산다.** PTY 를 못 띄우는 것(자식 프로세스 상한 등)은
                            // 있을 수 있는 일이고, 그때 앱이 죽으면 이미 열린 세션까지 잃는다.
                            // ── 검색 줄을 누르면 포커스가 간다 (W8.15) ──────────────────
                            //
                            // **밴드 판정은 중립이 소유한다**(`sidebar.headerHit` 이 `.search` 를 낸다).
                            // 그 줄은 §2m.46 이후 **그려만 있고 죽어 있었다.**
                            if (r == .search) {
                                if (!search_focused) {
                                    search_focused = true;
                                    search_focus_changes += 1;
                                    // **주인은 하나다**(위 짝).
                                    if (agent_search_focused) {
                                        agent_search_focused = false;
                                        agent_search_focus_changes += 1;
                                    }
                                    sidebar_redraws += 1;
                                    rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                }
                                continue;
                            }
                            if (r == .new_workspace and sessions.items.len < max_win_sessions) {
                                // **지금 크기로 만든다.** 활성 표면의 격자가 창이 아는 최신 값이다.
                                if (app_window.active()) |a| spawn_opts.size = a.core.size;
                                if (spawnWinSession(allocator, &sessions, &tab_ptrs, &app_window, &runtime, &next_session_id, spawn_opts)) {
                                    session_spawns += 1;
                                    refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                                    // 새 세션을 **바로 활성으로** 만든다 — 만들고 안 보여 주면
                                    // 눌린 것이 화면에 안 나타난다.
                                    //
                                    // **보는 것도 터미널로 돌린다.** `selectTab` 만 하면 파일을 보는
                                    // 중에 ＋ 를 눌렀을 때 세션은 생기는데 화면은 파일 그대로다 —
                                    // 위 규칙이 말하는 바로 그 실패다(적대적 검증 1회차 실측).
                                    _ = app_window.selectTab(sessions.items.len - 1);
                                    active_view = .{ .terminal = sessions.items.len - 1 };
                                    sidebar_redraws += 1;
                                    rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                } else |_| {
                                    session_spawn_failures += 1;
                                }
                            }
                        } else if (next_slot) |s| {
                            sidebar_card_clicks += 1;
                            sidebar_last_slot = s;
                            // ── ✕ 를 누르면 닫힌다 (W8.14) ──────────────────────────────
                            //
                            // **히트테스트는 중립이 소유한다**(`sidebar.closeButton`) — 그리는 쪽과
                            // **같은 `Columns`** 를 넘기므로 "보이는 칸 = 눌리는 칸" 이다(그 함수 doc).
                            // 여기서 산수로 잡으면 gutter·inset 이 바뀔 때 한쪽만 움직인다.
                            //
                            // **선택보다 먼저 본다.** 뒤에 두면 ✕ 를 눌러도 카드가 선택될 뿐이다.
                            close_blk: {
                                const cc = sidebar_card_columns orelse break :close_blk;
                                if (maru.chrome.components.sidebar.closeButton(@floatFromInt(m.x_px), cc, cell_w)) {
                                    close_clicks += 1;
                                    // **카드가 자기 정체를 든다.** 슬롯 번호에서 산수로 되돌리면
                                    // 검색이 목록을 거르는 순간 번호와 실물이 갈린다(W8.15).
                                    const src = if (s < sidebar_cards.items.len) sidebar_cards.items[s].source else SidebarCard.Source{ .session = 0 };
                                    if (src == .file) {
                                        const fi = src.file;
                                        if (fi < open_files.items.len) {
                                            var gone = open_files.orderedRemove(fi);
                                            gone.deinit(allocator);
                                            file_closes += 1;
                                            // **뒤쪽 색인이 하나씩 앞으로 당겨진다.** 보고 있던 것이
                                            // 그 뒤였다면 따라 당겨야 하고, 닫은 것 자체였다면
                                            // 터미널로 돌아간다 — 안 그러면 없는 파일을 가리킨다.
                                            active_view = switch (active_view) {
                                                .file => |a| if (a == fi)
                                                    ActiveView{ .terminal = app_window.active_tab }
                                                else if (a > fi)
                                                    ActiveView{ .file = a - 1 }
                                                else
                                                    ActiveView{ .file = a },
                                                .terminal => |t| ActiveView{ .terminal = t },
                                            };
                                            refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                                            sidebar_redraws += 1;
                                            rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                        }
                                    } else {
                                        // ── 세션을 닫는다 (W8.16) ───────────────────────────
                                        //
                                        // 계약이 정한 그대로다 — 프롬프트면 즉시, 실행 중이면 보류.
                                        // Windows 에 모달이 없어 **보류 = 안 닫음**이고, 그 사실을
                                        // 수치로 남긴다(조용히 죽이지 않는다).
                                        switch (closeWinSession(allocator, io, &sessions, &tab_ptrs, &app_window, &runtime, src.session, false)) {
                                            .closed => {
                                                session_closes += 1;
                                                // **pump 를 다시 건다.** 루프는 첫 세션 것을 보는데
                                                // 그것이 닫혔을 수 있다(포인터로 보므로 값만 바꾸면 된다).
                                                pump = sessions.items[0].pump;
                                                // **보고 있던 것이 파일이면 그대로 둔다.** 배경
                                                // 세션 하나를 닫았다고 문서에서 튕겨 나오면 안 된다
                                                // (적대적 검증 1회차). 터미널을 보고 있었을 때만
                                                // 번호를 다시 맞춘다 — 그 번호는 방금 당겨졌다.
                                                if (active_view == .terminal) active_view = .{ .terminal = app_window.active_tab };
                                                refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                                                sidebar_redraws += 1;
                                                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                            },
                                            .busy_needs_confirm => {
                                                // **조용히 죽이지 않고 묻는다.** 여기가 §2m.77 이
                                                // "모달이 선행" 이라 적어 둔 자리다.
                                                session_close_busy += 1;
                                                pending_close_id = if (src.session < sessions.items.len) sessions.items[src.session].surface.id else null;
                                                confirm_state.show(maru.i18n.t(.app_close_running), .{
                                                    .confirm = maru.i18n.t(.btn_close),
                                                    .cancel = maru.i18n.t(.common_cancel),
                                                });
                                                confirm_shows += 1;
                                            },
                                            .last_session => session_close_last += 1,
                                            .out_of_range => {},
                                        }
                                    }
                                    continue;
                                }
                            }
                            // **경계는 `sessions.len` 이다** — 그 뒤 슬롯은 연 파일이다(목록을 짓는
                            // `refreshSidebarCards` 와 같은 순서를 쓴다).
                            const sel_src = if (s < sidebar_cards.items.len) sidebar_cards.items[s].source else SidebarCard.Source{ .session = 0 };
                            if (sel_src == .file) {
                                const fi = sel_src.file;
                                if (fi < open_files.items.len and !(active_view == .file and active_view.file == fi)) {
                                    active_view = .{ .file = fi };
                                    file_view_switches += 1;
                                    sidebar_redraws += 1;
                                    rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                }
                                continue;
                            }
                            // **카드를 누르면 그 세션으로 간다.** 판정은 중립이 소유한다
                            // (`AppWindow.selectTab` — 범위 밖이면 false).
                            const ti = sel_src.session;
                            if (ti != app_window.active_tab and app_window.selectTab(ti)) {
                                active_view = .{ .terminal = ti };
                                tab_switches += 1;
                                sidebar_redraws += 1;
                                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                            }
                        }
                    }
                    continue;
                }
                // ── 도크 스크롤 (W8.7) ──────────────────────────────────────────────────
                //
                // **포인터가 있는 영역이 굴러간다.** 활성 뷰가 아니라 **가리키는 곳**이 기준이다 —
                // 그것이 이 저장소의 다른 영역 판정(`regionAt`)과 같은 규칙이고, 마우스를 도크에
                // 두고 굴렸는데 터미널이 굴러가면 놀란다.
                if (region == .dock_content and m.kind == .wheel) {
                    const notches = wheel_acc_dock.feed(m.wheel_delta);
                    if (notches != 0) {
                        const lines = win32_mouse.WheelAccumulator.linesForNotches(notches, wheel_lines_per_notch);
                        // **상한은 콘텐츠가 정한다.** 넘겨 굴리면 빈 바닥이 보이고, 못 굴리면 마지막
                        // 행에 못 닿는다.
                        const content_h: u32 = @intCast(dock_rows.items.len *| cell_h);
                        const max_scroll: u32 = content_h -| geom.tree_content.h;
                        const delta: i64 = @as(i64, lines) * @as(i64, @intCast(cell_h));
                        const next: i64 = @as(i64, dock_scroll_px) - delta;
                        const clamped: u32 = @intCast(std.math.clamp(next, 0, @as(i64, max_scroll)));
                        if (clamped != dock_scroll_px) {
                            dock_scroll_px = clamped;
                            dock_scrolls += 1;
                            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                        }
                    }
                    continue;
                }
                if (region != .terminal and m.kind != .capture_lost) {
                    dock_pointer_events += 1;
                    // ── 뷰 바: 칸을 누르면 도크 내용이 바뀐다 (W8.7c2) ──────────────────
                    //
                    // **칸 기하도 슬롯 순서도 중립이 소유한다** — `dock_view_bar.slotAtPoint` 와
                    // `dock_panel.View.forSlot`. 여기서 다시 나누면 그린 칸과 눌리는 칸이 갈린다.
                    if (region == .view_bar and m.kind == .left_up) {
                        const bar = maru.chrome.components.dock_view_bar.Rect{
                            .x = geom.view_bar.x,
                            .y = geom.view_bar.y,
                            .w = geom.view_bar.w,
                            .h = geom.view_bar.h,
                        };
                        if (m.x_px >= 0 and m.y_px >= 0) {
                            if (maru.chrome.components.dock_view_bar.slotAtPoint(bar, cell_w, @intCast(m.x_px), @intCast(m.y_px))) |slot| {
                                if (maru.session.dock_panel.View.forSlot(slot)) |next_view| if (next_view != dock_view) {
                                    dock_view = next_view;
                                    view_switches += 1;
                                    // 뷰가 바뀌면 기본 폭이 달라질 수 있다(`defaultRightPtForView`).
                                    geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px, status_bar_px);
                                    rebuildStatusBar(allocator, &status_cells, geom.status_bar, cell_w, cell_h, &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &status_uploads, status_items, &status_frames, &status_dropped, &status_placed, &status_outside, &status_mismatch, &status_rebuilds);
                                    if (win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h)) |size|
                                        resizeAllSessions(&runtime, sessions.items, size, io);
                                    rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {
                                        dock_rebuild_failures += 1;
                                    };
                                };
                            }
                        }
                        continue;
                    }
                    // ── 에이전트 뷰의 포인터 (W8.11) ────────────────────────────────────
                    //
                    // **SCM 과 같은 길이다** — 표면이 자기 좌표로 판정하고, 인텐트를 상태에 적용한
                    // 뒤 바뀌었으면 다시 그린다. 이 배선이 없던 동안 카드 셰브런과 그룹 헤더가
                    // **그려지는데 안 눌리는 죽은 컨트롤**이었다(§2m.56 이 한계로 적어 뒀다).
                    if (dock_view == .agent_sessions and region == .dock_content) {
                        if (agent_built) |*b| {
                            const lx = @as(f64, @floatFromInt(m.x_px)) - @as(f64, @floatFromInt(geom.tree_content.x));
                            const ly = @as(f64, @floatFromInt(m.y_px)) - @as(f64, @floatFromInt(geom.tree_content.y));
                            const kind: maru.chrome.ui.interaction.UiPointerPhase = switch (m.kind) {
                                .moved => .move,
                                .left_down => .down,
                                .left_up => .up,
                                else => continue,
                            };
                            const routed = agent_surface.pointer(b, &agent_state, kind, lx, ly);
                            var changed = routed.dirty;
                            if (routed.intent) |intent| {
                                agent_pointer_intents += 1;
                                // ── 새로고침 (W8.12) ───────────────────────────────────────
                                //
                                // **비동기가 되어서야 배선할 수 있는 인텐트다.** 훑기를 그 자리에서
                                // 기다리던 때는 이것을 누르면 창이 몇 초씩 멈췄을 것이다 — 그래서
                                // "모델이 없다" 가 아니라 **막고 있었기 때문에** 빠져 있었다.
                                // ── 검색 줄을 누르면 포커스가 간다 (W8.15) ─────────────────
                                //
                                // 인텐트도 렌더도 **중립이 이미 갖고 있었다**(`focus_search`,
                                // `props.search`·`search_focused`·`search_cursor_visible`) — 없던 것은
                                // 키의 주인뿐이다.
                                if (intent == .focus_search) {
                                    if (!agent_search_focused) {
                                        agent_search_focused = true;
                                        agent_search_focus_changes += 1;
                                        // **포커스 주인은 하나다.** 둘이 동시에 켜지면 앞서 보는
                                        // 쪽이 키를 삼켜, 사용자는 "여기를 눌렀는데 글자가 안
                                        // 들어간다" 를 겪는다(실측: `focused=true chars=0`).
                                        // **눌렀으면 화면이 답해야 한다.** 포커스만 바꾸고 안
                                        // 그리면 캐럿이 안 서서 "눌렸는지" 를 알 수가 없다 —
                                        // 실제 마우스로 캡처하다 드러났다(합성 판정은 값만 봤다).
                                        agent_opts.search = agent_search.query.items;
                                        agent_opts.search_focused = true;
                                        agent_state.invalidateTree();
                                        rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                                        agent_redraws += 1;
                                        if (search_focused) {
                                            search_focused = false;
                                            search_focus_changes += 1;
                                            rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                        }
                                    }
                                }
                                if (intent == .refresh) {
                                    if (agent_backend) |*ab| if (home_dir) |home| {
                                        const r = submitAgentScan(agent_counting.allocator(), ab, home);
                                        // 훑는 중이면 백엔드가 거절한다 — 그것은 실패가 아니라
                                        // "이미 하고 있다" 이므로 이유를 덮어쓰지 않는다.
                                        if (r.len == 0) {
                                            agent_refresh_submits += 1;
                                            // **다시 훑기 시작이다** — 이 값을 안 되돌리면 새로고침
                                            // 동안 아이콘이 안 죽어 "눌렀는데 아무 일도 없다" 가 된다.
                                            agent_scan_finished = false;
                                        }
                                    };
                                }
                                var intent_arena = std.heap.ArenaAllocator.init(allocator);
                                defer intent_arena.deinit();
                                if (applyAgentIntent(intent_arena.allocator(), agent_arena.allocator(), &agent_archive, &agent_state, &agent_items, intent)) {
                                    changed = true;
                                    agent_applied_intents += 1;
                                    // **항목이 바뀌면 옵션도 그것을 봐야 한다** — 표면은 `opts.items`
                                    // 를 그리므로 슬라이스를 갱신 안 하면 옛 목록이 남는다.
                                    agent_opts.items = agent_items.items;
                                    // **라벨도 함께 옮긴다** — 목록만 뒤집고 이 값을 두면 헤더가
                                    // 거짓말을 한다("Newest first" 라고 적힌 채 오래된 것이 위에).
                                    agent_opts.sort_order = agent_archive.sort;
                                }
                            }
                            if (changed) {
                                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                                agent_redraws += 1;
                            }
                        }
                        continue;
                    }
                    // ── 소스 컨트롤 뷰의 포인터 (W8.7c2) ────────────────────────────────
                    //
                    // **표면이 자기 좌표로 판정한다** — `Built` 의 tree 는 뷰포트 원점(0,0) 기준이라
                    // 도크 원점을 빼고 넘긴다. 그리기에서 더한 것과 **같은 값**이다.
                    if (dock_view == .source_control and region == .dock_content) {
                        if (scm_built) |*b| {
                            const lx = @as(f64, @floatFromInt(m.x_px)) - @as(f64, @floatFromInt(geom.tree_content.x));
                            const ly = @as(f64, @floatFromInt(m.y_px)) - @as(f64, @floatFromInt(geom.tree_content.y));
                            const phase: maru.chrome.ui.interaction.UiPointerPhase = switch (m.kind) {
                                .moved => .move,
                                .left_down => .down,
                                .left_up => .up,
                                else => continue,
                            };
                            const routed = scm_surface.pointer(b, &scm_state, phase, lx, ly);
                            var changed = routed.dirty;
                            if (routed.intent) |intent| {
                                if (scm_state.apply(intent)) {
                                    changed = true;
                                    scm_dock_intents += 1;
                                }
                            }
                            if (changed) {
                                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {
                                    dock_rebuild_failures += 1;
                                };
                                scm_dock_redraws += 1;
                            }
                        }
                        continue;
                    }
                    if (m.kind == .left_up) {
                        // **행 판정도 중립이 소유한다**(`file_tree_layout.rowAtLocalY`).
                        const local_y = @as(f64, @floatFromInt(m.y_px)) - @as(f64, @floatFromInt(geom.tree_content.y));
                        if (region == .dock_content and local_y >= 0) {
                            // **그린 행 수를 쓴다** — `dock_rows.items.len` 을 쓰면 안 그린 행이 눌린다(적대적 검증
                            // 실측: 110 행짜리 디렉터리에서 도크 맨 아래가 그리지 않은 29 행을 냈다).
                            if (maru.session.file_tree_layout.rowAtLocalY(cell_h, dock_scroll_px, local_y, dock_rows.items.len)) |row| {
                                dock_row_clicks += 1;
                                dock_last_row = row;
                                // ── 폴더를 누르면 펼쳐진다 ──────────────────────────────
                                //
                                // **셰브런이 그려져 있으면 눌려야 한다.** 그전에는 세기만 해서,
                                // 펼칠 수 있어 보이는 줄이 죽은 컨트롤이었다(사용자 보고).
                                // 경로는 **행이 들고 있다** — 여기서 다시 만들지 않는다.
                                if (row < dock_rows.items.len) {
                                    // ── 파일 줄을 누르면 열린다 (W8.13) ──────────────────
                                    //
                                    // §2m.55 가 "파일 행은 아직 아무 일도 안 한다" 로 남겨 둔 자리다.
                                    // **경로는 행이 들고 있다**(폴더와 같은 규율) — 다시 만들지 않고,
                                    // `buildRows` 가 그 메모리를 해제하므로 넘기기 전에 복사한다.
                                    // **`recent_file` 도 파일이다.** 라벨·아이콘을 내는 다른 세 곳은
                                    // 이미 `.file, .recent_file` 을 함께 받는데 여기만 `.file` 이었다 —
                                    // 그러면 똑같이 생긴 줄이 눌리는 것과 안 눌리는 것으로 갈린다
                                    // (방금 고친 죽은 컨트롤과 같은 결함, 적대적 검증 3회차).
                                    const clicked_file_path: ?[]const u8 = switch (dock_rows.items[row]) {
                                        .file, .recent_file => |fr| fr.path,
                                        else => null,
                                    };
                                    if (clicked_file_path) |fp| {
                                        const owned = allocator.dupe(u8, fp) catch continue;
                                        // `openFileFor` 가 자기 몫을 따로 복사하므로 이것은 항상 놓는다.
                                        defer allocator.free(owned);
                                        // **이미 열려 있으면 그것으로 간다**(창당 경로 유일성).
                                        var found: ?usize = null;
                                        for (open_files.items, 0..) |*of, fi|
                                            if (std.mem.eql(u8, of.path, owned)) {
                                                found = fi;
                                                break;
                                            };
                                        // **연 순간은 색인이 그대로여도 보여 준다**(W8.18a) — 다시
                                        // 누른 사람은 그 카드를 보러 온 것이다.
                                        sidebar_reveal_request = true;
                                        if (found) |fi| {
                                            file_reopens += 1;
                                            active_view = .{ .file = fi };
                                        } else switch (openFileFor(allocator, io, owned)) {
                                            .opened => |of| {
                                                open_files.append(allocator, of) catch {
                                                    var tmp = of;
                                                    tmp.deinit(allocator);
                                                    continue;
                                                };
                                                file_opens += 1;
                                                active_view = .{ .file = open_files.items.len - 1 };
                                            },
                                            // **못 여는 것을 조용히 넘기지 않고, 이유도 안 뭉갠다.**
                                            // `.md` 는 계약상 WebView 본문이라 W8.6 이 선행이고,
                                            // 읽기 실패는 결함이거나 4 MiB 상한이다 — 다른 사실이다.
                                            else => |why| {
                                                file_rejects += 1;
                                                last_reject = std.meta.activeTag(why);
                                                continue;
                                            },
                                        }
                                        refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                                        // **목록만 고치면 화면은 그대로다.** 실측 캡처에서 편집기는
                                        // 떴는데 사이드바에 그 파일 카드가 없었다 — 카드 **수**를
                                        // 보는 판정은 그것을 못 본다(모델은 맞았으니까).
                                        sidebar_redraws += 1;
                                        rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                                        continue;
                                    }
                                    const toggle_path: ?[]const u8 = switch (dock_rows.items[row]) {
                                        .directory => |dir| dir.path,
                                        .root => |r| r.path,
                                        else => null,
                                    };
                                    if (toggle_path) |tp| if (dock_root) |rp| {
                                        // **경로가 행 메모리를 가리킨다.** `buildRows` 가 그 목록을
                                        // 다시 지으면서 해제하므로, 넘기기 전에 복사한다.
                                        const owned_path = allocator.dupe(u8, tp) catch continue;
                                        defer allocator.free(owned_path);
                                        var submitted = false;
                                        if (toggleTreeRow(allocator, &dock_tree, if (tree_backend) |*b| b else null, &dock_rows, rp, owned_path, &submitted)) {
                                            if (submitted and tree_expand_submit_spin == null) tree_expand_submit_spin = spins;
                                            dock_row_toggles += 1;
                                            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                                        }
                                    };
                                }
                            }
                        }
                    }
                    // **터미널로 안 흘린다.** 흘리면 도크를 눌렀는데 셸에 선택이 생긴다.
                    continue;
                }

                // **캡처를 뺏겼으면 드래그만 끝낸다.** 버튼을 뗀 자리를 모르므로 선택을 건드리면
                // 안 된다 — 좌표 없이 확장하면 선택이 좌상단까지 끌려간다.
                if (m.kind == .capture_lost) {
                    dragging = false;
                    click_tracker.reset();
                    wheel_acc.reset();
                    // 호버 중복 억제도 푼다 — 창을 벗어났다 돌아왔을 때 **첫 이동이 stale 로 막히면**
                    // 그 셀에서 리포트가 한 번 빠진다.
                    last_motion_cell = null;
                    capture_losses += 1;
                    continue;
                }

                // **격자는 코어에게 묻는다.** 스왑체인 픽셀에서 유도하면 리사이즈 중에 코어가 아직 옛
                // 크기일 때 **없는 셀로 clamp** 된다 — 그 좌표로 선택을 확장하면 코어가 거절하거나
                // 엉뚱한 줄을 잡는다. 트래킹 모드와 함께 **한 번의 락에서** 읽는다.
                const snap: struct { tracking: maru.terminal.MouseTracking, cols: u16, rows: u16 } = blk: {
                    active.lockCore(io);
                    defer active.unlockCore(io);
                    break :blk .{
                        .tracking = active.core.mouse_tracking,
                        .cols = active.core.size.cols,
                        .rows = active.core.size.rows,
                    };
                };
                const tracking = snap.tracking;
                const cols = snap.cols;
                const rows = snap.rows;
                const to_shell = win32_mouse.reportsToShell(tracking != .none, m.mods);

                // ── 편집기를 굴린다 (W8.13) ────────────────────────────────────────────
                //
                // **파일이 활성이면 터미널이 아니라 편집기가 굴러간다.** 29 행 뷰포트에 100 줄짜리
                // 파일을 띄워 놓고 못 굴리면 연 것이 아니다.
                //
                // **상한은 중립이 정한다**(`viewport.clampFirstRow`) — 여기서 산수로 잡으면 편집기
                // 스모크와 갈린다.
                //
                // ── 가로 축도 같은 자리에서 받는다 (W8.17c) ───────────────────────────
                //
                // **가로 스크롤이 기본이고 랩은 토글이다**(`native-editor-visual-mapping.md`) — 그
                // 기본 축에 입력이 없으면 창보다 긴 줄은 **잘린 채 끝이다**. 둘로 받는다:
                // 기울임 휠·터치패드의 `wheel_h`, 그리고 평범한 휠에 **Shift**(터미널이 이미 쓰는 관례).
                if ((m.kind == .wheel or m.kind == .wheel_h) and active_view == .file and active_view.file < open_files.items.len) {
                    const horizontal = m.kind == .wheel_h or (m.mods & win32_mouse.mod_shift) != 0;
                    const notches = if (horizontal) wheel_acc_h.feed(m.wheel_delta) else wheel_acc_editor.feed(m.wheel_delta);
                    if (notches == 0) continue;
                    const of = &open_files.items[active_view.file];
                    if (horizontal) {
                        // **부호가 축마다 다르다**: 세로 휠은 양수가 위(=왼쪽으로 본다), 가로 휠은
                        // 양수가 오른쪽이다. 한 부호로 뭉치면 한쪽이 거꾸로 간다.
                        const dir: i64 = if (m.kind == .wheel_h) notches else -@as(i64, notches);
                        const vis_cols: u32 = @max(1, geom.terminal.w / cell_w);
                        // 오른쪽 끝을 지나 굴리지 않는다 — 마지막 글자가 왼쪽 끝에 닿으면 거기가 끝이다.
                        // **끝을 여기서 세지 않는다** — 그린 막대가 알려 준 값을 쓴다(`hmax_col`).
                        // 산수를 여기 두면 거터 폭을 빼먹어 마지막 열들이 영영 안 온다(실측).
                        const max_col: u32 = of.hmax_col;
                        // 한 눈금에 뷰포트 1/4 — 세로가 시스템 설정(줄 수)을 따르는 것과 달리 가로에는
                        // 그런 설정이 없다. 너무 작으면 긴 줄 끝까지 수십 번을 굴려야 한다.
                        const step: i64 = dir * @as(i64, @intCast(@max(1, vis_cols / 4)));
                        const capped: u16 = @intCast(std.math.clamp(@as(i64, of.first_col) + step, 0, @as(i64, max_col)));
                        if (capped != of.first_col) {
                            of.first_col = capped;
                            editor_hscrolls += 1;
                        }
                        continue;
                    }
                    const lines = win32_mouse.WheelAccumulator.linesForNotches(notches, wheel_lines_per_notch);
                    const vis: u16 = @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(1, geom.terminal.h / cell_h)));
                    const next: i64 = @as(i64, @intCast(of.first_line)) - @as(i64, lines);
                    const max_top = editor_view.viewport.clampFirstRow(std.math.maxInt(usize), of.lines.items.len, vis);
                    const clamped: usize = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(max_top))));
                    if (clamped != of.first_line) {
                        of.first_line = clamped;
                        editor_scrolls += 1;
                    }
                    continue;
                }
                // ── 문서 위의 클릭도 셸로 안 간다 (적대적 검증 2회차) ────────────────
                //
                // 휠은 이미 편집기가 가로챈다. **클릭·드래그는 그대로 지나가고 있었다** — 문서를
                // 드래그하면 안 보이는 터미널에 선택이 생기고, 트래킹을 켠 TUI 에게는 **마우스
                // 리포트**가 날아간다(그 앱은 사용자가 자기를 클릭했다고 믿는다).
                //
                // 지금 이 뷰는 읽기 전용이라 삼킨다. 편집기 히트테스트(§2m.24)는 이미 중립에 있고,
                // 캐럿·선택 모델이 붙는 슬라이스에서 여기에 이어 붙이면 된다.
                // ── 가로 막대를 끈다 (W8.17c) ─────────────────────────────────────────
                //
                // **좌표는 pane 로컬이다** — 중립이 그 사각 안에서 막대를 세웠고(`buildComposedEditor`
                // 의 `inner`), 그린 자리와 잡히는 자리의 주인이 둘이 되면 안 된다.
                if (active_view == .file and active_view.file < open_files.items.len) {
                    const of = &open_files.items[active_view.file];
                    const lx = @as(f64, @floatFromInt(m.x_px)) - @as(f64, @floatFromInt(geom.terminal.x));
                    const ly = @as(f64, @floatFromInt(m.y_px)) - @as(f64, @floatFromInt(geom.terminal.y));
                    switch (m.kind) {
                        .left_down => if (editor_last_hbar) |bar| {
                            // thumb 밖을 누르면 **그 자리로 뛴 뒤** 잡은 것으로 친다(중립 규칙).
                            if (hbar_drag.begin(bar, lx, ly)) |jumped| {
                                of.first_col = @intCast(@min(@as(u32, of.hmax_col), jumped / @max(1, cell_w)));
                                editor_hdrags += 1;
                            }
                        },
                        .moved => hbar_drag.absorb(lx, ly),
                        // **여기서 끝내지 않는다.** 뗀 순간에 `end` 하면 마지막으로 흡수한 자리가
                        // tick 에 닿기 전에 사라진다 — 빠른 플릭이 통째로 무시된다(실측: 합성
                        // 제스처가 한 스핀에 다 들어와 `drags=0` 이었다). 적용은 tick 이 하고,
                        // 그 다음에 끝낸다.
                        .left_up, .capture_lost => hbar_drag_release = true,
                        else => {},
                    }
                }
                if (active_view == .file) {
                    mouse_over_file += 1;
                    continue;
                }
                // **가로 축을 가진 표면이 아직 편집기뿐이다.** 여기까지 오면 버린다 — 안 버리면
                // 아래 리포트 변환의 `unreachable` 에 걸린다(터미널에는 가로 휠 리포트가 없다).
                if (m.kind == .wheel_h) continue;
                if (m.kind == .wheel) {
                    // **눈금과 줄을 가른다.** 리포팅은 xterm 규약상 눈금당 한 번이고, 사용자 설정
                    // (`SPI_GETWHEELSCROLLLINES`)은 로컬 스크롤백이 한 눈금에 몇 줄을 갈지 정하는 값이다.
                    // 섞으면 이 기계 설정(10)에서 TUI 가 한 번 굴림에 열 칸씩 튄다.
                    const notches = wheel_acc.feed(m.wheel_delta);
                    if (notches == 0) continue;
                    const lines = win32_mouse.WheelAccumulator.linesForNotches(notches, wheel_lines_per_notch);
                    if (to_shell) {
                        // **휠 리포트에도 셀 좌표를 싣는다.** 앱이 그것으로 어느 pane 을 굴릴지 정한다
                        // (less·vim 분할) — (0,0)을 실으면 늘 좌상단이라고 말하는 셈이다. 창이 화면
                        // 기준 좌표를 주는 것은 창 쪽에서 이미 클라이언트 기준으로 바꿔 올린다.
                        const wcell = win32_mouse.cellFromPixel(m.x_px, m.y_px, cell_w, cell_h, cols, rows) orelse continue;
                        last_mouse_cell = wcell;
                        last_wheel_cell = wcell;
                        // **눈금당 한 번**이다(줄 수만큼이 아니다).
                        const button: u8 = if (notches > 0) win32_mouse.button_wheel_up else win32_mouse.button_wheel_down;
                        var n: i32 = @intCast(@abs(notches));
                        while (n > 0) : (n -= 1) {
                            runtime.enqueueCoreCommand(active.id, .{ .report_mouse = .{
                                .button = button,
                                .col = wcell.col,
                                .row = wcell.row,
                                .x_px = @intCast(@max(m.x_px, 0)),
                                .y_px = @intCast(@max(m.y_px, 0)),
                                .pressed = true,
                                .motion = false,
                                .mods = win32_mouse.reportModifiers(m.mods),
                            } }, io) catch {
                                core_command_drops += 1;
                            };
                            mouse_report_commands += 1;
                        }
                        mouse_reports += 1;
                        continue;
                    }
                    // 사용자가 "휠 스크롤 안 함"으로 뒀으면 로컬 경로는 여기서 끝이다 — 0 줄짜리 명령을
                    // 넣고 `scrolls` 를 올리면 아무 일도 안 했는데 스크롤한 것으로 보고된다.
                    if (lines == 0) continue;
                    // alt 화면 + alternate scroll(DECSET 1007)이면 휠이 화살표 키가 된다.
                    var alt_bytes: []const u8 = &.{};
                    var key_buf: [maru.terminal.input.encoded_key_buffer_len]u8 = undefined;
                    {
                        active.lockCore(io);
                        defer active.unlockCore(io);
                        if (active.core.alt_active and active.core.alternate_scroll) {
                            const key: maru.terminal.input.Key = if (lines > 0) .arrow_up else .arrow_down;
                            alt_bytes = active.core.encodeKey(.{ .key = key }, &key_buf) catch &.{};
                        }
                    }
                    if (alt_bytes.len > 0) {
                        // 프로그램이 화면을 다시 그리므로 **선택을 해제한다**(남으면 좌표가 어긋난 유령이다).
                        runtime.enqueueCoreCommand(active.id, .select_clear, io) catch {
                            core_command_drops += 1;
                        };
                        // **한 버퍼에 묶어 보낸다** — 줄마다 쓰면 빠른 플릭에서 PTY 버퍼가 차 나머지가 드랍된다.
                        var batch: [512]u8 = undefined;
                        const per_batch = batch.len / alt_bytes.len;
                        var remaining: u32 = @intCast(@abs(lines));
                        while (remaining > 0) {
                            const count = @min(remaining, @as(u32, @intCast(per_batch)));
                            var len: usize = 0;
                            var i: u32 = 0;
                            while (i < count) : (i += 1) {
                                @memcpy(batch[len..][0..alt_bytes.len], alt_bytes);
                                len += alt_bytes.len;
                            }
                            maru.app.host.sendInputToActiveSurface(&app_window, &runtime, .{ .bytes = batch[0..len] }) catch break;
                            remaining -= count;
                        }
                        alt_scrolls += 1;
                        continue;
                    }
                    runtime.enqueueCoreCommand(active.id, .{ .scroll = @as(isize, lines) }, io) catch {
                        core_command_drops += 1;
                    };
                    scrolls += 1;
                    continue;
                }

                const cell = win32_mouse.cellFromPixel(m.x_px, m.y_px, cell_w, cell_h, cols, rows) orelse continue;
                last_mouse_cell = cell;

                if (to_shell) {
                    const is_motion = m.kind == .moved;
                    if (is_motion) {
                        // 버튼 없는 이동(hover)은 any(1003)일 때만 리포트한다.
                        if (!dragging and tracking != .any) continue;
                        // 드래그 중 이동은 button(1002)·any(1003)만 받는다 — 코어도 같은 가드를 갖지만
                        // 여기서 걸러야 **큐에 넣지도 않는다**.
                        if (dragging and tracking != .button and tracking != .any) continue;
                        // **셀이 바뀔 때만 보낸다 — 드래그도 마찬가지다.** `WM_MOUSEMOVE` 는 픽셀마다
                        // 오는데 셀은 안 바뀐다. 드래그를 예외로 두면 창을 가로질러 끄는 동안 같은
                        // 리포트가 PTY 에 수백 개 쏟아진다(xterm 도 셀 단위로 낸다).
                        if (last_motion_cell) |last| {
                            if (last.row == cell.row and last.col == cell.col) continue;
                        }
                        last_motion_cell = cell;
                    }
                    const button: u8 = switch (m.kind) {
                        .left_down, .left_up => win32_mouse.button_left,
                        .middle_down, .middle_up => win32_mouse.button_middle,
                        .right_down, .right_up => win32_mouse.button_right,
                        .moved => if (dragging) win32_mouse.button_left else win32_mouse.button_none,
                        // 셋 다 위에서 이미 `continue` 했다(가로 휠은 터미널 리포트에 없다).
                        .wheel, .wheel_h, .capture_lost => unreachable,
                    };
                    const pressed = switch (m.kind) {
                        .left_up, .right_up, .middle_up => false,
                        else => true,
                    };
                    if (m.kind == .left_down) dragging = true;
                    if (m.kind == .left_up) dragging = false;
                    runtime.enqueueCoreCommand(active.id, .{ .report_mouse = .{
                        .button = button,
                        .col = cell.col,
                        .row = cell.row,
                        .x_px = @intCast(@max(m.x_px, 0)),
                        .y_px = @intCast(@max(m.y_px, 0)),
                        .pressed = pressed,
                        .motion = is_motion,
                        .mods = win32_mouse.reportModifiers(m.mods),
                    } }, io) catch {
                        core_command_drops += 1;
                    };
                    mouse_report_commands += 1;
                    mouse_reports += 1;
                    continue;
                }

                // **우클릭은 `input.right_click` 이 정한다** — 기본값이 `paste` 다(PuTTY/X11 식, 사용자
                // 결정: `config/theme.zig` `RightClick`). 트래킹 중이면 위에서 이미 리포팅으로 갔다.
                if (m.kind == .right_down) {
                    switch (right_click_action) {
                        .paste => {
                            // 화음과 **같은 함수**를 부른다 — 규칙(bracketed 래핑·ESC 치환·보호 게이트)을
                            // 두 곳에 복사하면 한쪽만 고쳐진다. 그리고 그 규칙이 보안 규칙이다.
                            try pasteClipboardIntoActive(allocator, io, window.hwnd, &app_window, &runtime, stderr, paste_protection, bracketed_paste_is_safe, &paste_out);
                            right_click_pastes += 1;
                        },
                        // context 메뉴는 chrome 이 있어야 한다(W8). 지금은 아무것도 하지 않고 센다 —
                        // 조용히 무시하면 "우클릭이 안 먹는다"의 원인을 못 찾는다.
                        .menu => right_click_menus_unimplemented += 1,
                        // 트래킹이 아닌데 `reporting` 으로 뒀으면 보낼 곳이 없다. 무동작이 맞다.
                        .reporting => {},
                    }
                    continue;
                }

                // 로컬 선택. **좌버튼만** — 트래킹 아닌 상태의 중클릭은 무시한다.
                switch (m.kind) {
                    .left_down => {
                        const now_ns = std.Io.Clock.awake.now(io).nanoseconds;
                        const kind = click_tracker.classify(
                            @intCast(@divTrunc(now_ns, std.time.ns_per_ms)),
                            m.x_px,
                            m.y_px,
                            double_click_ms,
                            click_slop_x,
                            click_slop_y,
                        );
                        switch (kind) {
                            .single => {
                                dragging = true;
                                runtime.enqueueCoreCommand(active.id, .{ .select_start = .{
                                    .row = cell.row,
                                    .col = cell.col,
                                    .block = win32_mouse.blockSelection(m.mods),
                                } }, io) catch {
                                    core_command_drops += 1;
                                };
                                selections += 1;
                            },
                            .double => {
                                // **UTF-8 경계에서 자른다.** 고정 64 바이트 버퍼를 `@min` 으로 그냥 끊으면
                                // 여러 바이트 문자 한가운데가 잘리고, 코어의 `selectWordAt` 은 잘못된 UTF-8 을
                                // 만나면 `Utf8View.init` 이 실패해 **구분자를 전부 버린다**(하나도 아니고 전부).
                                // 그러면 더블클릭이 조용히 "공백만 경계" 로 되돌아간다. `。、「」…` 처럼 3 바이트
                                // 문자로 채우면 22 자에서 그 경계를 밟는다. macOS 도 같은 헬퍼를 쓴다.
                                var sw: maru.session.core_command.SelectWord = .{ .row = cell.row, .col = cell.col };
                                const n = maru.width.truncateToBoundary(default_word_separators, sw.separators.len);
                                @memcpy(sw.separators[0..n], default_word_separators[0..n]);
                                sw.sep_len = @intCast(n);
                                runtime.enqueueCoreCommand(active.id, .{ .select_word = sw }, io) catch {
                                    core_command_drops += 1;
                                };
                                // **더블·트리플 직후의 up 이 그 선택을 지우면 안 된다** — 단어가 1칸이면
                                // "이동 없는 클릭" 판정에 걸려 즉시 해제된다.
                                dragging = false;
                                word_selections += 1;
                            },
                            .triple => {
                                runtime.enqueueCoreCommand(active.id, .{ .select_line = cell.row }, io) catch {
                                    core_command_drops += 1;
                                };
                                dragging = false;
                                line_selections += 1;
                            },
                        }
                    },
                    .moved => {
                        if (!dragging) continue;
                        runtime.enqueueCoreCommand(active.id, .{ .select_extend = .{
                            .row = cell.row,
                            .col = cell.col,
                        } }, io) catch {
                            core_command_drops += 1;
                        };
                        extends += 1;
                    },
                    .left_up => {
                        if (!dragging) continue;
                        dragging = false;
                        runtime.enqueueCoreCommand(active.id, .{ .select_extend_or_collapse = .{
                            .row = cell.row,
                            .col = cell.col,
                        } }, io) catch {
                            core_command_drops += 1;
                        };
                    },
                    else => {},
                }
            },
        };

        // ── 세션 **전부**를 드레인한다 (W8.8⒞) ──────────────────────────────────────────────
        //
        // `AppFrameLoop.tickWithFrameBuilder` 는 자기 pump **하나만** 비운다. macOS 도 tick 이 모든
        // Term pump 를 돈다 — 같은 모양으로, 우리가 드레인하고 요약만 넘긴다.
        //
        // **무엇을 위해서인지 정확히 적는다**(처음에 틀리게 적었다): `process_in_reader = true` 라
        // **셸 출력은 리더 스레드가 코어에 직접 적용한다** — pump 를 안 비워도 배경 세션 화면은
        // 채워진다(실측: 배경 pump 를 막은 뮤턴트에서 `background_ink` 가 그대로였다). pump 가
        // 나르는 것은 **종료·read_error** 다. 안 비우면 배경 세션이 끝난 것을 아무도 못 보고 큐가
        // 자란다.
        //
        // **요약은 활성 세션 것을 넘긴다.** 프레임을 만드는 것은 활성 표면 하나이고, 종료 판정도
        // 그 세션의 것이어야 한다(다른 탭이 끝났다고 창을 닫으면 안 된다).
        var active_drain: maru.app.RuntimePumpDrainSummary = .{};
        for (sessions.items, 0..) |s, i| {
            const ds = s.pump.drainAvailable() catch continue;
            if (i == app_window.active_tab) active_drain = ds;
        }
        var tick = try loop.tickAfterDrainWithFrameBuilder(active_drain, builder);
        defer tick.deinit(allocator);
        counts.add(tick.frame.render_frame);
        if (tick.ended()) ended = true;

        // **IME 후보창을 커서에 붙인다**(§2k). 조합이 시작될 때가 아니라 **커서가 움직일 때마다**
        // 갱신한다 — IME 는 조합을 시작하는 순간의 위치를 쓰므로, 그 전에 최신값이 들어 있어야 한다.
        // 값이 그대로면 부르지 않는다(IME 가 무시하긴 하지만 매 프레임 IMM 컨텍스트를 여는 비용을 뺀다).
        if (app_window.active()) |active| {
            const cur: struct { row: u16, col: u16 } = blk: {
                active.lockCore(io);
                defer active.unlockCore(io);
                break :blk .{ .row = active.core.screen.cursor.row, .col = active.core.screen.cursor.col };
            };
            const changed = last_ime_caret == null or
                last_ime_caret.?.row != cur.row or last_ime_caret.?.col != cur.col;
            if (changed) {
                window.setImeCaret(cur.row, cur.col, cell_w, cell_h);
                last_ime_caret = .{ .row = cur.row, .col = cur.col };
                ime_caret_updates += 1;
            }
        }

        // **OSC 52 를 배수한다.** 셸이 클립보드 읽기·쓰기를 요청하면 코어가 pending 으로 들고 있고
        // 플랫폼이 정책을 확인한 뒤 OS 를 만진다 — 코어가 OS 를 직접 만지지 않는 것이 그 설계다.
        if (app_window.active()) |active| {
            active.lockCore(io);
            const pending = active.core.pendingClipboardWrite();
            const want_read = active.core.clipboardReadPending();
            // **락 안에서 OS 를 부르지 않는다** — 클립보드 호출은 다른 프로세스를 기다릴 수 있어(소유자가
            // 지연 렌더링하면 블록된다) 그 사이 PTY 리더가 코어 락에 막힌다. 복사해 두고 락 밖에서 쓴다.
            var write_copy: ?[]u8 = null;
            if (pending.len > 0) write_copy = allocator.dupe(u8, pending) catch null;
            // 복사에 실패했는데도 pending 을 비우면 요청이 **아무 흔적 없이** 사라진다. 세어서 알린다.
            if (pending.len > 0 and write_copy == null) clipboard_errors += 1;
            if (pending.len > 0) active.core.clearClipboardWrite();
            if (want_read) active.core.clearClipboardRead();
            active.unlockCore(io);

            if (write_copy) |bytes| {
                defer allocator.free(bytes);
                // **성공했을 때만 센다.** `catch` 밖에서 올리면 실패한 쓰기가 `osc52_writes=1` 로 보고돼
                // 성공처럼 읽힌다 — 이 이식에서 계속 경계해 온 "성공처럼 보이는 실패"다.
                if (win32_clipboard.write(allocator, window.hwnd, bytes)) |_| {
                    osc52_writes += 1;
                } else |err| {
                    try stderr.print("  warning: clipboard write failed({s}, Win32 error {d})\n", .{ @errorName(err), win32_clipboard.last_error });
                    clipboard_errors += 1;
                }
            }
            if (want_read) {
                osc52_reads += 1;
                // **읽기는 정책이 막는다.** `osc52.read` 기본값이 `deny` 다 — 원격/내부 프로그램이 로컬
                // 클립보드를 탈취하는 것을 막는 사용자 결정이고(`config/theme.zig`), macOS 도 같은 판정을
                // 한다. pending 은 정책과 무관하게 위에서 이미 소비했다(안 그러면 매 tick 재트리거된다).
                //
                // `allow` 일 때 보낼 응답(`ESC ] 52 ; <Pc> ; <base64> ST`)을 여기서 만들지 않는다. 그
                // 인코더(`formatOsc52ReadResponse`)가 **중립이 아니라 macOS `app_session.zig` 안에** 있어,
                // Windows 가 쓰려면 중립으로 들어올려야 한다 — 그것은 이 슬라이스 밖의 설계 결정이라
                // 사용자에게 보고하고 정한다(AGENTS.md 핵심 원칙).
                if (osc52_read_policy == .allow) osc52_reads_denied_unimplemented += 1;
            }
        }

        // ⑴ 아틀라스가 커졌으면 텍스처를 다시 만든다(중립 쪽이 전체를 무효화하고 재배치했으므로 안전하다).
        const now_w = renderer_state.atlas.config.atlas_width_px;
        const now_h = renderer_state.atlas.config.atlas_height_px;
        if (now_w != atlas_w or now_h != atlas_h) {
            try pipeline.resizeAtlas(now_w, now_h);
            atlas_w = now_w;
            atlas_h = now_h;
            atlas_resizes += 1;
            // **도크 프레임의 UV 가 옛 아틀라스 기준이다** — 다시 안 지으면 도크 글자가 엉뚱한
            // 글리프로 바뀐다(중립 쪽은 터미널 프레임만 무효화·재배치한다).
            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {
                dock_rebuild_failures += 1;
            };
        }

        // ⑵ 이 프레임의 새 글리프만 올린다.
        const rf = tick.frame.render_frame.glyph_raster_frame;
        for (rf.uploads) |up| {
            const bytes = rf.pixels[up.bytes_offset..][0..up.byte_count];
            pipeline.uploadAtlasRegion(up.slot.x_px, up.slot.y_px, up.slot.width_px, up.slot.height_px, bytes, up.bytes_per_row) catch |err| {
                try stderr.print("  warning: atlas upload failed({s}) slot=({d},{d}) {d}x{d}\n", .{ @errorName(err), up.slot.x_px, up.slot.y_px, up.slot.width_px, up.slot.height_px });
                continue;
            };
            region_uploads += 1;
        }

        // **선택 하이라이트를 매 프레임 채운다.** `CellColors.selection` 은 기본값이 `null` 이고
        // 그것은 "선택을 투영하지 않는다" 는 뜻이다 — 커서와 **정확히 같은 함정**이다(그 doc 참조).
        // 안 채우면 드래그가 코어까지 가서 선택 상태가 생기는데 **화면에는 아무 일도 안 일어난다**.
        // 실측으로 그렇게 걸렸다: `selections` 카운터는 오르는데 파란 띠가 없었다.
        //
        // 읽기라 메인 스레드에서 해도 된다(코어 mutate 만 리더 위임이다 — 같은 루프의
        // `active.core.mouse_tracking` 과 같은 자리다). macOS 도 같은 한 줄이다.
        // **OSC 4 팔레트도 매 프레임 가져온다.** 앱이 `OSC 4` 로 색을 바꾸면 그것이 config 보다
        // 우선한다(우선순위: OSC4 → config → xterm256). 안 가져오면 `config_palette` 만 보여
        // **앱이 바꾼 색이 화면에 안 나온다** — 선택·커서와 같은 "상태는 생기는데 안 그려지는" 부류다.
        //
        // **포인터가 아니라 복사본을 준다.** 코어는 리더 스레드가 계속 쓰고 있어, 프레임 만드는 동안
        // 코어 포인터를 들고 있으면 값이 중간에 바뀔 수 있다(macOS 도 같은 이유로 복사한다).
        if (app_window.active()) |a| {
            palette_copy = a.core.paletteOverride().*;
            colors.palette = &palette_copy;
        }
        colors.selection = if (app_window.active()) |a| a.core.selectionViewportSpan() else null;
        if (colors.selection != null) selection_frames += 1;

        // ⑶ 중립 투영 → D3D11 셀.
        const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(
            allocator,
            tick.frame.render_frame.glyph_quad_frame,
            tick.frame.render_frame.draw_list.cells,
            colors,
        );
        defer allocator.free(native);
        // **터미널을 자기 사각형에 놓는다**(§2m.31). 원점을 안 찍으면 도크가 있어도 터미널이 창
        // 왼쪽 위에서 시작해 도크 밑으로 깔린다.
        maru.renderer.metal_frame.setCellsPaneOrigin(native, geom.terminal.x, geom.terminal.y);

        // ── 목록이 줄면 도크도 자기 범위로 돌아온다 (W8.18b) ────────────────────────────
        //
        // **접기·새로고침·정렬은 목록을 줄인다.** 그때 스크롤을 그대로 두면 내용이 없는 자리를 보게
        // 된다 — 편집기가 겪은 그 실패(`first=1000000` 에서 빈 문서)의 도크 짝이다. macOS 는 행을
        // 다시 지을 때마다 `clampFileTreeScroll` 을 부르는데(그 함수 doc: *"호출부에 인라인으로 두면
        // 테스트가 이 산술을 복제한다"*), Windows 는 **휠이 올 때만** 상한을 봤다.
        //
        // **그리기 직전에 한 번 본다** — 목록을 바꾸는 자리가 여럿이라(펼치기·접기·스캔 결과·검색)
        // 그 각각에 넣으면 한 곳이 빠진다. 창이 커져 뷰포트가 넓어지는 경우도 여기서 함께 잡힌다.
        if (dock_view == .explorer) {
            const dock_content_h: u32 = @intCast(dock_rows.items.len *| cell_h);
            const dock_max: u32 = dock_content_h -| geom.tree_content.h;
            if (dock_scroll_px > dock_max) {
                dock_scroll_px = dock_max;
                dock_clamps += 1;
                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
            }
        }
        // ── 눈이 따라간다 (W8.18a) ──────────────────────────────────────────────────────
        //
        // **활성 카드가 화면 밖이면 옮겨 준다.** 파일을 열면 그 카드가 활성이 되는데 세션이 쌓이면
        // 목록 아래라, 화면은 그대로여서 "눌렀는데 아무 표시가 없다" 로 보인다(계획서 W8.18a).
        //
        // **얼마나 굴릴지는 중립이 정한다**(`sidebar.scrollToSlot`) — 여기서 산수로 잡으면 그린
        // 자리와 갈린다. 이미 보이면 그 함수가 지금 값을 그대로 주므로 **매 프레임 불러도 안전**하고,
        // 그래서 사용자가 손으로 굴린 자리를 빼앗지 않는다.
        {
            const active_slot_now = sidebarActiveSlot(sidebar_cards.items, active_view);
            // **바뀐 순간**과 **연 순간**을 함께 본다. 색인이 그대로여도(같은 카드를 다시 열었다)
            // 사용자는 그 카드를 보러 온 것이다.
            const want_reveal = sidebar_reveal_request or active_slot_now != last_active_slot;
            last_active_slot = active_slot_now;
            sidebar_reveal_request = false;
            if (want_reveal and sidebar_header_h != 0 and geom.sidebar.h > sidebar_header_h) {
                const rws_rv = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, active_slot_now);
                const mm_rv = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
                const next_off = maru.chrome.components.sidebar.scrollToSlot(
                    rws_rv,
                    active_slot_now,
                    mm_rv,
                    geom.sidebar.h - sidebar_header_h,
                    sidebar_scroll_px,
                );
                if (next_off != sidebar_scroll_px) {
                    sidebar_scroll_px = next_off;
                    sidebar_reveals += 1;
                    // **셀을 다시 짓는다** — 사이드바 셀은 클릭 때 지어져 옛 offset 을 들고 있다.
                    rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                }
            }
        }
        cells.clearRetainingCapacity();
        try cells.ensureTotalCapacity(allocator, native.len + dock_cells.items.len + sidebar_cells.items.len + titlebar_cells.items.len);
        // **사이드바·도크가 먼저다** — 그리는 순서가 z 순서이고, 터미널 글자가 그 배경에 덮이면 안 된다.
        cells.appendSliceAssumeCapacity(sidebar_cells.items);
        cells.appendSliceAssumeCapacity(dock_cells.items);
        // ── 스크롤바 (W8.10) ────────────────────────────────────────────────────────────
        //
        // **내용 위에 얹는다** — 그리는 순서가 z 순서다. 거터는 상시 비워 둔 자리라 겹칠 것이
        // 없지만, 부분만 보이는 첫 행이 거터로 새는 경우가 있어 순서로 못 박는다.
        //
        // **매 프레임 다시 잰다.** 상태(offset·행 수)가 바뀌면 thumb 이 따라와야 하는데, 캐시하면
        // "굴렸는데 막대가 안 움직인다" 가 된다 — 쿼드 넷이라 값이 싸다.
        dock_bar = if (dock_view == .explorer)
            dockScrollbarGeometry(geom, dock_rows.items.len, cell_h, dock_scroll_px)
        else
            null;
        if (dock_bar) |bar| appendScrollbarCells(allocator, &cells, bar, &chrome_tokens) catch {};
        sidebar_bar = blk: {
            if (sidebar_header_h == 0) break :blk null;
            const rws = sidebarRowsFor(allocator, &sidebar_rows_scratch, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view));
            const mm = maru.chrome.components.sidebar.Metrics.init(cell_h, cell_h);
            break :blk sidebarScrollbarGeometry(geom, sidebar_header_h, maru.chrome.components.sidebar.contentHeight(rws, mm), sidebar_scroll_px);
        };
        if (sidebar_bar) |bar| appendScrollbarCells(allocator, &cells, bar, &chrome_tokens) catch {};
        // ── 터미널 자리에 무엇이 서는가 (W8.13) ──────────────────────────────────────────
        //
        // 파일이 활성이면 **그 사각형에 편집기가 선다.** 터미널 셀은 아예 안 넣는다 — 겹쳐 그리면
        // 두 화면이 포개져 글자가 서로를 뚫고 나온다.
        var editor_cells_drawn: usize = 0;
        // **편집기가 아틀라스를 키우면 그 신호가 사라진다.** 이 루프의 ⑴ 은 `atlas_w/h` 가 바뀐 것을
        // 보고 도크를 다시 짓는데, 편집기 프레임은 `syncAtlasTexture` 를 스스로 불러 그 값을 **먼저**
        // 갱신한다 — 다음 프레임의 ⑴ 은 아무 변화도 못 본다. 그러면 사이드바·도크는 옛 아틀라스
        // 기준 UV 를 **영영** 들고 있게 된다(상태바가 겪은 그 실패: 이름이 `fea` 세 글자만 남았다).
        //
        // **못 밀었다.** 이 작업부하에서는 아틀라스가 안 커진다(256×256 으로 줄여도 `resizes=0` —
        // 축출·재사용으로 끝난다). 기전은 코드로 확실하므로 좁게 막고, 판정은 **지어내지 않는다**.
        const atlas_before_w = atlas_w;
        const atlas_before_h = atlas_h;
        const showing_file = active_view == .file and active_view.file < open_files.items.len;
        const term_first = cells.items.len;
        if (showing_file) {
            const of = &open_files.items[active_view.file];
            // **그리기 직전에 상한을 다시 잡는다.** 휠은 그때의 뷰포트로 clamp 하는데, 창이 **커지면**
            // 보이는 행이 늘어 상한이 줄어든다 — 그러면 방금까지 옳던 위치가 범위를 넘어 **빈 문서**가
            // 그려진다(실측: `first=1000000` 에서 `rows=0 cells=2`). 상한은 중립이 정한다.
            {
                const vis_now: u16 = @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(1, geom.terminal.h / cell_h)));
                const capped = editor_view.viewport.clampFirstRow(of.first_line, of.lines.items.len, vis_now);
                if (capped != of.first_line) {
                    of.first_line = capped;
                    editor_clamps += 1;
                }
                // **가로도 같다.** 창이 넓어지면 갈 수 있는 오른쪽 끝이 줄어드는데, 휠이 올 때만
                // 잡으면 그때까지 문서 오른쪽에 **빈 자리**가 남는다(세로가 겪은 그 실패의 짝).
                // **끌던 막대를 여기서 적용한다**(중립이 말하는 tick) — move 마다 적용하면 한
                // 프레임에 수십 번 다시 그린다. `takeOffset` 은 결과가 같으면 `null` 을 준다.
                if (hbar_drag.takeOffset()) |off| {
                    const want: u32 = @min(@as(u32, of.hmax_col), off / @max(1, cell_w));
                    if (want != of.first_col) {
                        of.first_col = @intCast(want);
                        editor_hdrags += 1;
                    }
                }
                if (hbar_drag_release) {
                    hbar_drag.end();
                    hbar_drag_release = false;
                }
                // 상한은 **직전 프레임의 막대**가 준다(아래 `hmax_col`) — 첫 프레임에는 0 이라
                // 못 굴리지만, 그 프레임이 그려지는 즉시 열린다.
                if (of.first_col > of.hmax_col) {
                    of.first_col = of.hmax_col;
                    editor_clamps += 1;
                }
            }
            const ed_host = EditorHost{
                .renderer_state = &renderer_state,
                .shaper = builder.shaper,
                .rasterizer = builder.rasterizer,
                .pipeline = pipeline,
                .atlas_w = &atlas_w,
                .atlas_h = &atlas_h,
                .cell_w = cell_w,
                .cell_h = cell_h,
            };
            if (buildComposedEditor(allocator, ed_host, of, geom.terminal, ops_buf, &chrome_tokens, cell_w, cell_h)) |built_ed| {
                var be = built_ed;
                defer be.deinit(allocator);
                cells.ensureUnusedCapacity(allocator, be.cells.items.len) catch {};
                for (be.cells.items) |c| cells.appendAssumeCapacity(c);
                editor_cells_drawn = be.cells.items.len;
                editor_last_cells = be.cells.items.len;
                editor_last_rows = be.written.visual_rows;
                editor_last_digest = d3d11_cells.cellsDigest(be.cells.items);
                // **중립이 세운 가로 막대를 그대로 들고 있는다** — 여기서 자리를 다시 계산하면
                // 그린 것과 판정이 갈린다(막대 자리의 주인은 하나다).
                editor_last_hbar = be.written.horizontal_scrollbar;
                // **갈 수 있는 오른쪽 끝은 그린 막대가 안다.** `max_offset_px` 는 중립이 thumb 을
                // 세운 그 값이라(`scroll_area.thumbSpan`), 여기서 `max_cols - 보이는 열` 을 다시
                // 세면 **거터 폭만큼 어긋난다** — 실측으로 끝까지 굴려도 마지막 41 열이 안 왔고
                // thumb 이 트랙 오른쪽에 **안 닿았다**(`thumb_right=310 track_right=342`).
                of.hmax_col = if (be.written.horizontal_scrollbar) |b|
                    @intCast(@min(
                        @as(u32, maru.chrome.components.editor_view.frame.max_first_col),
                        b.max_offset_px / @max(1, cell_w),
                    ))
                else
                    0;
                // **자기 사각형 밖으로 나간 셀을 센다**(도크가 이미 쓰는 그 검사). 원점이 틀리면
                // 화면은 이상한데 개수·행 수 판정은 조용하다 — 편집기는 사이드바·도크보다 **뒤에**
                // 그려지므로 새면 그것들을 덮는다.
                var out_n: usize = 0;
                for (be.cells.items) |c| {
                    if (c.rect[0] < @as(f32, @floatFromInt(geom.terminal.x)) or
                        c.rect[0] + c.rect[2] > @as(f32, @floatFromInt(geom.terminal.x + geom.terminal.w)) or
                        c.rect[1] < @as(f32, @floatFromInt(geom.terminal.y)) or
                        c.rect[1] + c.rect[3] > @as(f32, @floatFromInt(geom.terminal.y + geom.terminal.h))) out_n += 1;
                }
                editor_cells_outside_last = out_n;
                editor_cells_outside_max = @max(editor_cells_outside_max, out_n);
                editor_frames += 1;
            } else |_| editor_build_failures += 1;
            if (atlas_w != atlas_before_w or atlas_h != atlas_before_h) {
                editor_atlas_growths += 1;
                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, dock_scroll_px, &dock_scroll_shift, &dock_draw_start, &dock_tree_top_px, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, &view_bar_glyph_top, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }, .{ .state = &agent_state, .opts = agent_opts, .built = &agent_built }) catch {};
                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
            }
        } else for (native) |n| cells.appendAssumeCapacity(win32_terminal.cellFromNative(n, cell_w, cell_h, atlas_w, atlas_h));
        // **여기까지가 터미널이다.** 아래 침범 판정이 이 구간만 봐야 한다 — 띠를 함께 세면 띠가 창
        // 폭을 가로지르고 `y=0` 에서 시작하므로 **두 판정이 영원히 0 이 아니게 되어 죽는다**
        // (실측: 둘 다 15600 = 띠 26 셀 × 600 프레임).
        const term_last = cells.items.len;
        // **띠는 맨 위다** — 터미널·도크 위에 얹혀야 캡션 버튼이 안 가려진다.
        cells.appendSlice(allocator, titlebar_cells.items) catch {};
        // **상태바도 맨 위다** — 창 전폭이라 터미널·도크 위에 얹힌다(그 아래가 이미 비워져 있다:
        // `compute` 가 창 높이에서 먼저 깎았다).
        cells.appendSlice(allocator, status_cells.items) catch {};
        // **마우스로 고른 것을 여기서 실행한다.** 이벤트 루프 안에서 세션을 지우면 그 프레임의
        // 나머지가 사라진 것을 만진다 — 키 갈래는 곧바로 실행해도 되지만(그 뒤에 `continue` 로
        // 프레임을 빠져나간다) 마우스는 다른 처리가 뒤따를 수 있어 한 박자 미룬다.
        if (confirm_pending_click) |act| {
            confirm_pending_click = null;
            switch (act) {
                .confirmed => {
                    confirm_accepts += 1;
                    confirm_state.dismiss();
                    if (sessionIndexById(sessions.items, pending_close_id)) |ci| {
                        switch (closeWinSession(allocator, io, &sessions, &tab_ptrs, &app_window, &runtime, ci, true)) {
                            .closed => {
                                session_closes += 1;
                                pump = sessions.items[0].pump;
                                if (active_view == .terminal) active_view = .{ .terminal = app_window.active_tab };
                                refreshSidebarCards(allocator, &sidebar_cards, sessions.items, open_files.items, folder_name, search.query.items) catch {};
                                sidebar_redraws += 1;
                                rebuildSidebarCells(allocator, &sidebar_cells, geom, titlebar_px, sidebar_w, cell_w, cell_h, sidebar_cards.items, sidebarActiveSlot(sidebar_cards.items, active_view), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame, &sidebar_header_frame, &sidebar_header_h, &sidebar_header_icon_band, &sidebar_header_icon_glyphs, &sidebar_header_search_glyphs, &sidebar_header_outside, &sidebar_card_over_header, &sidebar_cells_clipped, &sidebar_cards_visible, &sidebar_header_drawn, sidebar_hover_slot, sidebar_hover_header, sidebar_scroll_px, &sidebar_first_visible, &sidebar_first_band_y, &sidebar_partial, &sidebar_active_band_y, &sidebar_card_cols, &sidebar_card_columns, search.query.items, search_focused) catch {};
                            },
                            else => {},
                        }
                    }
                    pending_close_id = null;
                },
                .cancelled => {
                    confirm_cancels += 1;
                    confirm_state.dismiss();
                    pending_close_id = null;
                },
                .alternate => {},
            }
        }
        // ── 확인 모달은 **가장 위**다 (W8.16b) ─────────────────────────────────────────
        //
        // 그리는 순서가 z 순서다 — 띠·상태바보다도 뒤에 얹어야 그 위를 덮는다. 모달이 무엇을 덮는지가
        // 곧 "무엇을 못 누르는가" 라, 입력 삼킴과 같은 자리에 있어야 한다.
        confirm_cells_drawn = 0;
        if (confirm_state.open) {
            if (appendConfirmCells(allocator, &cells, &confirm_state, confirmProps(client_w, client_h, cell_w, cell_h, sidebar_w), &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &confirm_frame, &confirm_unpainted)) |n_drawn| {
                confirm_cells_drawn = n_drawn;
                // **그린 셀에서 상자의 가로 중앙을 도로 읽는다** — 내가 넘긴 값을 되읽으면 동어반복이다.
                var minx: f32 = std.math.floatMax(f32);
                var maxx: f32 = 0;
                for (cells.items[cells.items.len - n_drawn ..]) |c| {
                    minx = @min(minx, c.rect[0]);
                    maxx = @max(maxx, c.rect[0] + c.rect[2]);
                }
                confirm_center_x = @intFromFloat((minx + maxx) / 2);
            } else |_| confirm_draw_failures += 1;
        }
        last_cells = cells.items.len;

        // **터미널 셀이 도크 사각형에 들어가면 안 된다**(§2m.31 의 진짜 위험). 격자를 창 폭에서
        // 유도하는 실수는 화면에서 잘 안 보인다 — 도크 배경이 덮어 버리기 때문이다. 그래서 그림이
        // 아니라 **셀 좌표**로 잰다.
        {
            const dock_x0: f32 = if (geom.dock.w != 0) @floatFromInt(geom.dock.x) else std.math.floatMax(f32);
            const term_x0: f32 = @floatFromInt(geom.terminal.x);
            const term_y0: f32 = @floatFromInt(geom.terminal.y);
            for (cells.items[term_first..term_last]) |c| {
                if (c.rect[0] + c.rect[2] > dock_x0) term_cells_in_dock += 1;
                // 가장자리 글자 조각을 쫓는다 — 사각형 **왼쪽·위**로 삐져나간 셀이 있나.
                if (c.rect[0] < term_x0 or c.rect[1] < term_y0) term_cells_before_rect += 1;
            }
        }

        try present.beginFrame(clear);
        try pipeline.draw(cells.items, present.width_px, present.height_px);
        try present.present(false);
        frames += 1;
        _ = usleep(16_000);
    }
    if (close_requested) window.requestClose();

    try stdout.writeAll("maru.win32-terminal-smoke.v1\n");
    try stdout.print("dock_visible={} term_rect={d}x{d}+{d}+{d} dock_rect={d}x{d}+{d}+{d} divider_w={d}\n", .{
        dock_visible,
        geom.terminal.w,
        geom.terminal.h,
        geom.terminal.x,
        geom.terminal.y,
        geom.dock.w,
        geom.dock.h,
        geom.dock.x,
        geom.dock.y,
        geom.divider.w,
    });
    // **이것이 진짜 판정이다.** 셀이 도크에 들어갔는지만 보면 **속 빈다** — 셸 출력이 짧으면 격자를
    // 창 폭에서 잘못 유도해도 셀이 거기까지 안 닿는다(실측: 뮤턴트가 `terminal_size` 만 109x31 로
    // 달라지고 `term_cells_in_dock` 은 그대로 0 이었다). 격자 자체를 사각형과 견준다.
    try stdout.print("grid_follows_term_rect={} grid={d}x{d} want={d}x{d}\n", .{
        start.cols == want_cols and start.rows == want_rows,
        start.cols,
        start.rows,
        want_cols,
        want_rows,
    });
    // 부차 판정: 그려진 셀이 도크 사각형을 침범했나(원점을 안 찍었거나 클립이 없을 때 잡힌다).
    try stdout.print("term_cells_in_dock={d} term_cells_before_rect={d} dock_cells={d}\n", .{ term_cells_in_dock, term_cells_before_rect, dock_cells.items.len });
    // **사이드바 판정**(W8.8⒜1). `term_cells_before_rect` 가 사이드바 침범을 잡는다 — 터미널
    // 사각형이 이제 `x=180` 에서 시작하므로, 원점을 안 찍으면 그 수가 0 이 아니다(§2m.31 이
    // "검증 안 됐다" 고 적어 둔 배선이 여기서 처음 발동한다).
    try stdout.print("titlebar_px={d} caption_btn_w={d} caption_clicks={d} titlebar_cells={d}\n", .{ titlebar_px, caption_btn_w, caption_clicks, titlebar_cells.items.len });
    if (caption_judgeable) {
        // **동어반복이 아니다**: 내가 보낸 좌표를 되읽는 것이 아니라 **OS 의 창 상태**
        // (`IsZoomed`)를 읽는다. 히트테스트·라우팅·`toggleMaximize` 가 전부 이어져야 뒤집힌다.
        try stdout.print("caption_max_before={} after={} restored={} caption_toggle_ok={}\n", .{
            caption_max_before,
            caption_max_after,
            caption_max_restored,
            !caption_max_before and caption_max_after and !caption_max_restored,
        });
    } else {
        try stdout.print("caption_toggle=unjudgeable reason=no_titlebar\n", .{});
    }
    if (titlebar_px != 0) {
        // **OS 에게 직접 묻는 두 판정.** 위 캡션 판정은 우리 클라이언트 좌표 안에서만 돌아서
        // 프레임리스가 풀려도 초록이었다 — 여기가 그 구멍을 막는다.
        // `HTCAPTION=2`, `HTCLIENT=1`.
        try stdout.print("frameless_covers_window={} nchittest_strip={d} nchittest_button={d} nchittest_below={d} nchittest_sidebar_icon={d} frameless_wiring_ok={}\n", .{
            frameless_covers,
            nchittest_strip,
            nchittest_button,
            nchittest_below,
            nchittest_sidebar_icon,
            frameless_covers and nchittest_strip == 2 and nchittest_button == 1 and nchittest_below == 1 and
                nchittest_sidebar_icon == 1,
        });
    }
    status_bar: {
        // ── 하단 상태표시줄 (W8.9) ──────────────────────────────────────────────────────────
        //
        // **개수만 세면 속 빈다** — 배경 띠와 경계선은 항목이 하나도 없어도 그려진다. 그래서
        // **글리프 셀이 몇 장인지**와 **띠 밖으로 나간 것이 있는지**를 함께 낸다.
        //
        // **높이는 되읽지 않는다.** `status_bar_px` 를 그대로 적으면 내가 넘긴 값을 되읽는 동어반복이라,
        // 중립이 그것으로 무엇을 했는지는 안 보인다 — `geom.status_bar` 와 `geom.terminal` 을 낸다.
        const bar = geom.status_bar;
        // **끈 것은 실패가 아니다.** `status-bar.show = false` 는 사용자가 명시적으로 고른 상태이고
        // (계약 §2: 되돌릴 길이 있어야 한다), 그때 바가 없는 것이 **옳은 동작**이다. 하나로 접으면
        // 그 설정을 쓰는 기계에서 스모크가 거짓 실패를 낸다.
        if (status_bar_px == 0) {
            try stdout.print("status=unjudgeable reason=hidden_by_config term_bottom={d} client_h={d} reclaimed={}\n", .{
                geom.terminal.y + geom.terminal.h,
                client_h,
                geom.terminal.y + geom.terminal.h == client_h,
            });
            break :status_bar;
        }
        // **지은 것이 지금 기하와 같은가.** 창이 커진 뒤 다시 안 지으면 옛 사각형에 남는데
        // (실측 2026-08-26: y=574·w=984 에 남아 화면에서 사라졌다) 위 값들은 **전부 기하만 보므로**
        // 하나도 안 움직였다. 그래서 **실제로 지어 둔 배경 셀**과 지금 기하를 견준다 — 서로 다른
        // 곳에서 온 두 값이라 동어반복이 아니다.
        const built_rect: ?[4]f32 = if (status_cells.items.len == 0) null else status_cells.items[0].rect;
        const fresh = if (built_rect) |r|
            r[0] == @as(f32, @floatFromInt(bar.x)) and r[1] == @as(f32, @floatFromInt(bar.y)) and
                r[2] == @as(f32, @floatFromInt(bar.w)) and r[3] == @as(f32, @floatFromInt(bar.h))
        else
            false;
        const fits = bar.h == 0 or (bar.y + bar.h == client_h and bar.w == client_w);
        try stdout.print("status_bar=({d},{d},{d},{d}) status_full_width={} status_above_bottom={} status_cells={d} status_placed={d} status_dropped={d} status_outside={d} status_mismatch={d} status_rect_fresh={} status_rebuilds={d} term_bottom={d} status_ok={}\n", .{
            bar.x,
            bar.y,
            bar.w,
            bar.h,
            bar.w == client_w,
            fits,
            status_cells.items.len,
            status_placed,
            status_dropped,
            status_outside,
            status_mismatch,
            fresh,
            status_rebuilds,
            geom.terminal.y + geom.terminal.h,
            bar.h > 0 and bar.w == client_w and fits and status_placed > 0 and status_outside == 0 and
                status_mismatch == 0 and fresh and
                geom.terminal.y + geom.terminal.h <= bar.y,
        });
    }
    if (sb_bar_judgeable) {
        const b = sb_bar_seen.?;
        // **thumb 이 트랙 안이어야 한다** — 넘치면 목록 밖에 뜬다.
        const inside = b.thumb_y >= b.track_y and b.thumb_y + b.thumb_h <= b.track_y + b.track_h + 0.5;
        try stdout.print("sb_bar=({d:.0},{d:.0},{d:.0},{d:.0}) thumb=({d:.0},{d:.0}) hit_w={d:.0} max_off={d} off {d}->{d} drag_moves={d} track_clicks={d} drawn={} overlap={d} text_right={d} sb_bar_ok={}\n", .{
            b.track_x,
            b.track_y,
            b.track_w,
            b.track_h,
            b.thumb_y,
            b.thumb_h,
            b.hit_w,
            b.max_offset_px,
            sb_off_before,
            sb_off_after,
            bar_drag_moves,
            bar_track_clicks,
            sb_bar_drawn,
            sb_bar_overlap,
            @as(u32, sidebar_card_cols) *| cell_w,
            inside and b.thumb_h > 0 and b.max_offset_px > 0 and bar_drag_moves > 0 and sb_off_after > sb_off_before and
                sb_bar_drawn and sb_bar_overlap == 0 and
                // **글자가 쓸 수 있는 오른쪽 끝이 막대 왼쪽 안이어야 한다.** `overlap` 은 지금
                // 카드 이름이 짧아 **공허하다**(거터를 빼는 것을 잊어도 0 이었다 — 뮤턴트 실측).
                // 이 조건은 그리기가 **실제로 쓴 칸 수**를 보므로 그때 움직인다.
                @as(f32, @floatFromInt(@as(u32, sidebar_card_cols) *| cell_w)) <= b.track_x,
        });
    } else {
        try stdout.print("sb_bar=unjudgeable reason=no_overflow\n", .{});
    }
    if (db_judgeable) {
        const b = db_seen.?;
        try stdout.print("dock_bar=({d:.0},{d:.0},{d:.0},{d:.0}) thumb=({d:.0},{d:.0}) max_off={d} off {d}->{d} dock_bar_ok={}\n", .{
            b.track_x,
            b.track_y,
            b.track_w,
            b.track_h,
            b.thumb_y,
            b.thumb_h,
            b.max_offset_px,
            db_off_before,
            db_off_after,
            b.max_offset_px > 0 and db_off_after > db_off_before,
        });
    } else {
        // **왜 못 쟀는지 남긴다** — 그냥 빠지면 "도크는 안 본다" 가 조용해진다.
        try stdout.print("dock_bar=unjudgeable reason=no_overflow rows={d} content_h={d} viewport_h={d}\n", .{
            dock_rows.items.len,
            dock_rows.items.len *| cell_h,
            geom.tree_content.h,
        });
    }
    if (ag_click_judgeable) {
        // **목록이 줄어야 한다.** 인텐트 개수만 세면 속 빈다 — 적용이 안 돼도 인텐트는 난다.
        try stdout.print("agent_click: items {d}->{d} collapsed={d} expanded {?d}->{?d} reopened={d}/{d} kept={d} wrong={d} survived={} multi={d}->{d} first_still={} intents={d}/{d} redraws={d} agent_click_ok={}\n", .{
            ag_items_before,
            ag_items_after,
            ag_collapsed_after,
            ag_expand_before,
            ag_expand_after,
            ag_items_reopened,
            ag_collapsed_reopened,
            ag_kept_cards,
            ag_wrong_cards,
            ag_expand_survived,
            ag_multi_keys_before,
            ag_multi_keys_after,
            ag_multi_first_still,
            agent_applied_intents,
            agent_pointer_intents,
            agent_redraws,
            ag_items_after < ag_items_before and ag_collapsed_after > 0 and
                // **펼침도 붙어야 한다** — 그룹만 되고 카드가 죽어 있어도 위 조건은 참이다.
                ag_expand_before == null and ag_expand_after != null and
                // **되돌아와야 한다** — 접기만 되고 펴기가 죽어 있어도 위 조건은 전부 참이다.
                ag_items_reopened == ag_items_before and ag_collapsed_reopened == 0 and
                // **둘을 접고 하나만 폈을 때 남은 하나가 첫째여야 한다** — 번호→키 대응이
                // 흔들리면 엉뚱한 그룹이 펴진다.
                // **접은 그룹의 카드가 하나도 안 남아야 한다** — 개수만 보면 엉뚱한 것을 지워도 맞다.
                ag_wrong_cards == 0 and ag_kept_cards > 0 and
                // **펼침이 접기·펴기를 넘어 살아남아야 한다** — identity 를 쓰는 이유가 그것이다.
                ag_expand_survived and
                ag_multi_judgeable and ag_multi_keys_before == 2 and ag_multi_keys_after == 1 and
                ag_multi_first_still and
                agent_redraws > 0,
        });
    } else {
        try stdout.print("agent_click=unjudgeable reason=no_surface\n", .{});
    }
    {
        // **비동기가 진짜인가.** 토글한 프레임과 반영된 프레임이 **같으면** 아직 그 자리에서
        // 기다리는 것이다 — 예전 코드가 정확히 그랬다(400 회 `sleep(1ms)`). 개수만 세면 막고
        // 있어도 초록이므로 **프레임 차이**를 낸다.
        const sub = tree_expand_submit_spin orelse 0;
        const app = tree_expand_apply_spin orelse 0;
        const lag: i64 = @as(i64, @intCast(app)) - @as(i64, @intCast(sub));
        try stdout.print("tree_scan: applied={d} submit_spin={d} apply_spin={d} lag={d} tree_async_ok={}\n", .{
            tree_scan_applied,
            sub,
            app,
            lag,
            tree_expand_submit_spin != null and tree_expand_apply_spin != null and lag > 0,
        });
    }
    {
        // **이 둘은 판정이 아니라 관측값이다.** 세는 것은 "요청했다가 놓은 양" 이지 allocator 가
        // 실제로 돌려준 양이 아니다 — child 가 arena 면 `free` 가 no-op 인데도 이 계수는 줄어든다.
        // 그러니 여기에 `ok` 를 달면 40 MB 가 눌러앉아도 초록인 판정이 된다(실제로 그렇게 썼다가
        // 되돌렸다). **상주 여부의 판정은 DebugAllocator 의 누수 보고**가 맡는다(§2m.69).
        try stdout.print("agent_scan: apply_spin={d} reason={s} cards={d} req_peak_kb={d} unfreed_kb={d} agent_async_ok={}\n", .{
            agent_apply_spin orelse 0,
            agent_list_reason,
            agent_archive.cards.len,
            agent_counting.peak / 1024,
            agent_counting.live / 1024,
            agent_apply_spin != null and (agent_apply_spin.? > 0),
        });
    }
    if (open_judgeable) {
        // **네 가지를 함께 본다.** 카드 수만 보면 편집기가 빈 화면이어도 초록이고, 셀 수만 보면
        // 아무 파일이나 열려도 초록이다. 그래서 ⑴ 목록이 늘었나 ⑵ **다시 눌러도 안 늘었나**
        // (창당 경로 유일성) ⑶ 활성이 파일인가 ⑷ 편집기가 **행을 그렸나** 를 모은다.
        try stdout.print("open_file: path={s} opens={d} reopens={d} rejects={d} files {d}->{d} showing_file={} editor_cells={d} editor_rows={d} sidebar_digest {x}->{x} open_file_ok={}\n", .{
            open_target_buf[0..open_target_len],
            file_opens,
            file_reopens,
            file_rejects,
            open_files_after_first,
            open_files_after_second,
            open_showing_file,
            open_editor_cells,
            open_editor_rows,
            open_sidebar_digest_before,
            open_sidebar_digest_after,
            // **`reopens > 0` 이 빠지면 안 된다.** 두 번째 클릭이 대상을 못 찾으면 클릭 자체가
            // 안 일어나고 `files 1->1` 은 그대로 참이라, 유일성 검사가 **초록인 채 속이 빈다**.
            file_opens > 0 and
                file_reopens > 0 and
                open_sidebar_digest_after != open_sidebar_digest_before and
                open_files_after_first == open_files_after_second and
                open_showing_file and
                open_editor_cells > 0 and
                open_editor_rows > 0,
        });
    } else {
        try stdout.print("open_file=unjudgeable reason=no_zig_row_visible\n", .{});
    }
    if (keytest_judgeable) {
        try stdout.print("keys_while_file: seen={d} reached_terminal={d} keys_not_leaked={}\n", .{
            keys_while_file,
            keys_to_terminal_while_file,
            keys_while_file > 0 and keys_to_terminal_while_file == 0,
        });
    } else {
        try stdout.print("keys_while_file=unjudgeable reason=no_file_active\n", .{});
    }
    if (open_judgeable) {
        // **그린 적이 있어야 의미가 있다.** 편집기가 한 번도 안 그렸으면 "밖으로 안 나갔다" 는
        // 그냥 참이다 — 프레임 수를 함께 요구해 공허해지지 않게 한다.
        try stdout.print("editor_bounds: frames={d} outside_last={d} outside_max={d} editor_in_pane={}\n", .{
            editor_frames,
            editor_cells_outside_last,
            editor_cells_outside_max,
            editor_frames > 0 and editor_cells_outside_max == 0,
        });
        // 관측값이다(판정 아님) — 이 작업부하에서는 0 이라 판정으로 내면 공허하다.
        try stdout.print("editor_atlas_growths={d}{c}", .{ editor_atlas_growths, @as(u8, 10) });
    }
    if (cycle_opens > 0) {
        // **셀 수가 일정해야 한다** — 열 때마다 늘면 앞 프레임의 것이 남아 쌓이는 것이다.
        try stdout.print("modal_cycles: opens={d} closes={d} cells first={d} last={d} cycles_ok={}\n", .{
            cycle_opens,
            cycle_closes,
            cycle_first_cells,
            cycle_last_cells,
            cycle_opens >= 3 and cycle_closes >= 3 and cycle_first_cells > 0 and cycle_first_cells == cycle_last_cells,
        });
    }
    if (capmodal_judgeable) {
        // **창이 커졌으면 상자도 따라와야 한다.** 열려 있는지, 중앙이 창 중앙으로 옮겨졌는지 본다.
        try stdout.print("modal_follows_resize: client {d}->{d} center {d}->{d} cells {d}->{d} open={} follows={}\n", .{
            resize_client_before,
            resize_client_after,
            resize_center_before,
            resize_center_after,
            resize_cells_before,
            resize_cells_after,
            resize_open_after,
            resize_open_after and resize_client_after > resize_client_before and
                resize_center_after > resize_center_before,
        });
    }
    if (shift_judgeable) {
        // **지목한 그것이 죽어야 한다.** 개수만 보면 하나 줄었으니 초록인데, 죽은 것이 다른
        // 세션이면 사용자는 남기려던 것을 잃는다.
        try stdout.print("confirm_shift: victim_id={d} survived={} confirm_shift_ok={}\n", .{
            probe_victim_id,
            shift_target_survived,
            !shift_target_survived,
        });
    }
    if (capmodal_judgeable) {
        try stdout.print("caption_while_modal: max {}->{} caption_alive={}\n", .{
            capmodal_before,
            capmodal_after,
            capmodal_before != capmodal_after,
        });
    }
    if (cancel_judgeable) {
        try stdout.print("confirm_cancel: open_before={} open_after={} sessions {d}->{d} cancels={d} confirm_cancel_ok={}\n", .{
            cancel_open_before,
            cancel_open_after,
            cancel_sessions_before,
            cancel_sessions_after,
            confirm_cancels,
            cancel_open_before and !cancel_open_after and
                cancel_sessions_after == cancel_sessions_before and
                confirm_cancels > 0,
        });
    } else {
        try stdout.print("confirm_cancel=unjudgeable reason=need_three_sessions\n", .{});
    }
    if (modal_judgeable) {
        try stdout.print("confirm_modal: shows={d} open_after_click={} cells={d} sessions {d}->{d}(open)->{d} accepts={d} cancels={d} open_after_accept={} draw_fail={d} unpainted_quads={d} confirm_modal_ok={}\n", .{
            confirm_shows,
            modal_open_after_click,
            modal_cells,
            modal_sessions_before,
            modal_sessions_while_open,
            modal_sessions_after,
            confirm_accepts,
            confirm_cancels,
            modal_open_after_accept,
            confirm_draw_failures,
            confirm_unpainted,
            modal_open_after_click and
                modal_cells > 0 and
                modal_sessions_while_open == modal_sessions_before and
                !modal_open_after_accept and
                confirm_accepts > 0 and
                modal_sessions_after == modal_sessions_before - 1 and
                confirm_draw_failures == 0,
        });
    } else {
        try stdout.print("confirm_modal=unjudgeable reason=need_three_sessions\n", .{});
    }
    if (busy_judgeable) {
        try stdout.print("close_busy: refused={} sessions {d}->{d} tabs {d}->{d} active {d}->{d} alive={} close_busy_ok={}\n", .{
            busy_result_busy,
            busy_sessions_before,
            busy_sessions_after,
            busy_tabs_before,
            busy_tabs_after,
            busy_active_before,
            busy_active_after,
            busy_still_alive,
            busy_result_busy and
                busy_sessions_after == busy_sessions_before and
                busy_tabs_after == busy_tabs_before and
                busy_active_after == busy_active_before and
                busy_still_alive,
        });
    }
    if (multi_closes > 0) {
        try stdout.print("close_many: closes={d} sessions={d} tabs={d} dups={d} active_ok={} close_many_ok={}\n", .{
            multi_closes,
            multi_sessions,
            multi_tabs,
            multi_dups,
            multi_active_ok,
            multi_closes >= 3 and multi_sessions == multi_tabs and multi_dups == 0 and multi_active_ok,
        });
    } else {
        try stdout.print("close_many=unjudgeable reason=no_close\n", .{});
    }
    if (idcheck_judgeable) {
        // **닫고 다시 만들면 id 가 겹치나.** 라우팅이 그 값으로 세션을 가르므로, 겹치면 한 세션의
        // 출력이 다른 세션 화면에 간다 — 개수·이름 판정으로는 전혀 안 보인다.
        try stdout.print("session_ids: spawned={} err={s} count={d} duplicates={d} ids_unique={}\n", .{
            idcheck_spawned,
            idcheck_err[0..idcheck_err_len],
            idcheck_count,
            idcheck_dups,
            idcheck_spawned and idcheck_count > 0 and idcheck_dups == 0,
        });
    }
    if (sclose_judgeable) {
        // **탭도 함께 줄어야 한다** — 목록만 줄이고 `app_window.tabs` 를 두면 라우팅이 죽은 표면을 든다.
        try stdout.print("close_session: sessions {d}->{d} tabs {d}->{d} kept want={s} got={s} closes={d} busy={d} last={d} active_ok={} pump_rebound={} active want={s} got={s} close_session_ok={}\n", .{
            sclose_sessions_before,
            sclose_sessions_after,
            sclose_tabs_before,
            sclose_tabs_after,
            sclose_second_name[0..sclose_second_name_len],
            sclose_first_name[0..sclose_first_name_len],
            session_closes,
            session_close_busy,
            session_close_last,
            sclose_active_ok,
            sclose_pump_rebound,
            sclose_active_want[0..sclose_active_want_len],
            sclose_active_name[0..sclose_active_name_len],
            sclose_sessions_after == sclose_sessions_before - 1 and
                std.mem.eql(u8, sclose_active_want[0..sclose_active_want_len], sclose_active_name[0..sclose_active_name_len]) and
                sclose_pump_rebound and
                sclose_tabs_after == sclose_tabs_before - 1 and
                std.mem.eql(u8, sclose_second_name[0..sclose_second_name_len], sclose_first_name[0..sclose_first_name_len]) and
                sclose_active_ok and
                session_closes > 0,
        });
    } else {
        try stdout.print("close_session=unjudgeable reason=need_two_sessions\n", .{});
    }
    if (asearch_judgeable) {
        // **에이전트 목록은 그룹 헤더 + 카드다** — 전부 걸러지면 0 이어야 하고, 지우면 되돌아와야
        // 한다. 사이드바와 달리 카드 정체가 record index 라 색인이 안 흔들린다.
        try stdout.print("agent_search: focused={} chars={d} items {d}->{d}->{d} agent_search_ok={}\n", .{
            asearch_focused,
            agent_search_chars,
            asearch_items_before,
            asearch_items_after,
            asearch_items_restored,
            asearch_focused and
                agent_search_chars > 0 and
                asearch_items_before > 0 and
                asearch_items_after == 0 and
                asearch_items_restored == asearch_items_before,
        });
    } else {
        try stdout.print("agent_search=unjudgeable reason=no_search_node\n", .{});
    }
    if (search_judgeable) {
        try stdout.print("search: focused={} chars={d} query_len={d} cards {d}->{d}->{d} kept sessions={d} files={d} search_ok={}\n", .{
            search_focused_after_click,
            search_chars,
            search_query_drawn,
            search_cards_before,
            search_cards_after,
            search_cards_restored,
            search_sessions_after,
            search_files_after,
            search_focused_after_click and
                search_chars > 0 and
                search_cards_after < search_cards_before and
                search_sessions_after > 0 and
                search_files_after == 0 and
                search_cards_restored == search_cards_before,
        });
    } else {
        try stdout.print("search=unjudgeable reason=no_header\n", .{});
    }
    if (close_judgeable) {
        try stdout.print("close_file: files {d}->{d} kept want={s} got={s} clicks={d} closes={d} session_closes={d} x={d} close_file_ok={}\n", .{
            close_files_before,
            close_files_after,
            close_want_buf[0..close_want_len],
            close_got_buf[0..close_got_len],
            close_clicks,
            file_closes,
            session_closes,
            close_click_x,
            close_files_after == close_files_before - 1 and
                std.mem.eql(u8, close_want_buf[0..close_want_len], close_got_buf[0..close_got_len]) and
                close_view_ok and
                file_closes > 0,
        });
    } else {
        try stdout.print("close_file=unjudgeable reason=need_two_open_files\n", .{});
    }
    if (divfile_judgeable) {
        try stdout.print("divider_while_file: dock_w {d}->{d} divider_alive={}\n", .{
            divfile_dock_w_before,
            divfile_dock_w_after,
            divfile_dock_w_after > divfile_dock_w_before,
        });
    }
    if (oob_judgeable) {
        // **되돌아온 것만으로는 모자란다** — 0 으로 되돌려도 "되돌아왔다" 이다. **행을 그렸는지**를
        // 함께 본다(빈 문서가 이 결함의 증상이었다).
        try stdout.print("editor_oob: first={d} lines={d} rows={d} clamps={d} editor_oob_ok={}\n", .{
            oob_first_after,
            oob_lines,
            oob_rows_after,
            editor_clamps,
            oob_first_after < oob_lines and oob_rows_after > 0 and editor_clamps > 0,
        });
    }
    if (mousetest_judgeable) {
        try stdout.print("mouse_over_file: seen={d} term_selection {}->{} mouse_not_leaked={}\n", .{
            mouse_over_file,
            mouse_sel_before,
            mouse_sel_after,
            mouse_over_file > 0 and !mouse_sel_after,
        });
    }
    if (spawn_while_file_judgeable) {
        // **만든 것과 보여 준 것을 갈라 센다.** 세션 수만 보면 "만들었다" 로 초록인데 화면은
        // 파일 그대로일 수 있다 — 실제로 그랬다.
        try stdout.print("spawn_while_file: sessions {d}->{d} shows_terminal={} spawn_while_file_ok={}\n", .{
            spawn_while_file_sessions_before,
            spawn_while_file_sessions_after,
            spawn_while_file_shows_terminal,
            spawn_while_file_sessions_after > spawn_while_file_sessions_before and spawn_while_file_shows_terminal,
        });
    } else {
        try stdout.print("spawn_while_file=unjudgeable reason=no_file_active_or_session_cap\n", .{});
    }
    if (hscroll_judgeable) {
        // **그린 것이 실제로 바뀌었는지**까지 본다 — `first_col` 만 보면 내가 넣은 값을 되읽는다.
        try stdout.print("editor_hscroll: col {d}->{d} max_cols={d} hscrolls={d} digest {x}->{x} editor_hscroll_ok={}\n", .{
            hscroll_col_before,
            hscroll_col_after,
            hscroll_max_cols,
            editor_hscrolls,
            hscroll_digest_before,
            hscroll_digest_after,
            hscroll_max_cols > 0 and hscroll_col_after > hscroll_col_before and
                hscroll_digest_after != hscroll_digest_before,
        });
        // **막대가 서고, 그 thumb 이 따라 움직였는가.** 굴러가기만 하고 막대가 없으면 얼마나 남았는지
        // 알 길이 없고, 막대만 서고 안 따라오면 그것은 장식이다.
        try stdout.print("editor_hbar: before={?d:.1} after={?d:.1} track={?d:.1} hbar_ok={}\n", .{
            if (hbar_before) |b| b.thumb_x else null,
            if (hbar_after) |b| b.thumb_x else null,
            if (hbar_after) |b| b.track_w else null,
            hbar_before != null and hbar_after != null and hbar_after.?.thumb_x > hbar_before.?.thumb_x,
        });
        const thumb_right: f32 = if (hend_hbar) |b| b.thumb_x + b.thumb_w else 0;
        const track_right: f32 = if (hend_hbar) |b| b.track_x + b.track_w else 0;
        try stdout.print("editor_hend: col={d} max_cols={d} thumb_right={d:.1} track_right={d:.1} hend_ok={}\n", .{
            hend_col,
            hend_max_cols,
            thumb_right,
            track_right,
            hend_hbar != null and hend_col > hscroll_col_after and hend_col < hend_max_cols and
                @abs(thumb_right - track_right) <= 1.0,
        });
        try stdout.print("agent_busy: loading_frames={d} refreshing_frames={d} items {d}->{d} digest {x}->{x} settled_busy={} agent_busy_ok={}\n", .{
            agent_loading_frames,
            agent_refreshing_frames,
            notice_items_before,
            notice_items_during,
            notice_digest_idle,
            notice_digest_busy,
            notice_still_busy,
            // **첫 훑기에도 말했어야** 하고(`loading_frames > 0`), 새로고침 중에는 **같은 목록인데
            // 화면이 달라야** 한다 — 그 차이가 곧 "분석 중" 문구와 죽은 아이콘이다.
            agent_loading_frames > 0 and notice_judgeable and
                notice_items_during == notice_items_before and notice_digest_busy != notice_digest_idle and
                // **그리고 끝나면 내린다** — 안 내리면 늘 켜 두는 것과 같아 아무 말도 안 하는 셈이다.
                notice_settled_judgeable and !notice_still_busy,
        });
        try stdout.print("sidebar_clip: partial={d} clipped={d} over_header={d} clip_ok={}\n", .{
            clip_partial,
            clip_clipped,
            clip_over,
            // **자를 것이 있었어야**(`clipped > 0`) 이 판정이 무언가를 묻는다. 그리고 자른 뒤에는
            // 헤더 위에 **아무것도 없어야** 한다.
            clip_partial > 0 and clip_clipped > 0 and clip_over == 0,
        });
        try stdout.print("sidebar_rows_cap: cards={d} rows={d} off={d} last_visible={} drawn {d}+{d} rows_cap_ok={}\n", .{
            cap_cards,
            cap_rows,
            cap_off,
            cap_last_visible,
            cap_first_visible,
            cap_visible,
            // **열여섯을 넘겨 놓고** 물어야 이 판정이 무언가를 묻는다. 행 목록이 카드 수와 같아야
            // 하고(잘리지 않았다), 바닥까지 굴리면 마지막 카드가 통째로 보여야 한다.
            // **그린 것으로 판정한다** — 바닥까지 굴렸으면 빌더가 마지막 카드까지 그렸어야 한다.
            cap_cards > 16 and cap_rows == cap_cards and cap_last_visible and
                cap_first_visible + cap_visible == cap_cards,
        });
        try stdout.print("wheel_surfaces: sidebar {d}->{d} dock {d}->{d} surfaces_ok={}\n", .{
            leak_sidebar_before,
            leak_sidebar_after,
            leak_dock_before,
            leak_dock_after,
            // 사이드바는 **한 눈금이 안 됐으니 안 움직여야** 하고, 그 나머지가 도크로 새지 않았다면
            // 도크는 자기 한 눈금으로 **움직여야** 한다.
            leak_judgeable and leak_sidebar_after == leak_sidebar_before and leak_dock_after != leak_dock_before,
        });
        {
            // **상한은 접힌 뒤의 목록이 정한다** — 판정이 앞 값을 쓰면 아무것도 안 묻는다.
            const dc_content: u32 = @intCast(dclamp_rows_after *| cell_h);
            const dc_max: u32 = dc_content -| geom.tree_content.h;
            try stdout.print("dock_clamp: rows {d}->{d} off {d}->{d} max_after={d} drawn={d} draw_start={d}/{d} clamps={d} dock_clamp_ok={}\n", .{
                dclamp_rows_before,
                dclamp_rows_after,
                dclamp_off_before,
                dclamp_off_after,
                dc_max,
                dclamp_drawn_after,
                dclamp_draw_start_after,
                dclamp_off_after / @max(1, cell_h),
                dock_clamps,
                // **접기 전에 그 상한을 넘고 있어야** 이 판정이 무언가를 묻는다. 그리고 되돌아온
                // 자리에 **행이 그려져 있어야** 한다 — 값만 맞고 화면이 비면 고친 것이 아니다.
                dclamp_judgeable and dclamp_off_before > dc_max and dclamp_off_after <= dc_max and
                    dclamp_drawn_after > 0 and
                    // **그린 첫 행이 되돌아온 자리와 같은가** — 값만 고치고 셀을 다시 안 지으면
                    // 여기가 갈린다(뮤턴트가 그렇게 살아남았다).
                    dclamp_draw_start_after == dclamp_off_after / @max(1, cell_h),
            });
        }
        try stdout.print("sidebar_reveal: slot {d}->{d} visible {}->{} off {d}->{d} digest {x}->{x} reveals={d} reveal_ok={}\n", .{
            reveal_slot,
            reveal_slot_after,
            reveal_visible_before,
            reveal_visible_after,
            reveal_off_before,
            reveal_off_after,
            reveal_digest_before,
            reveal_digest_after,
            reveal_count,
            // **누르기 전에 화면 밖이어야** 이 판정이 무언가를 묻는다 — 이미 보이는 것을 "보인다" 고
            // 말하는 판정은 아무것도 안 지킨다.
            // **그린 것까지 본다** — offset 만 옮기고 셀을 다시 안 지으면 값은 맞는데 화면은 그대로다.
            reveal_judgeable and !reveal_visible_before and reveal_visible_after and reveal_count > 0 and
                reveal_digest_after != reveal_digest_before,
        });
        try stdout.print("hbar_jump: col {d}->{d} on_thumb {}->{} jump_ok={}\n", .{
            jump_col_before,
            jump_col_after,
            jump_on_thumb_before,
            jump_on_thumb_after,
            // **누르기 전에는 thumb 밖**이어야 이 판정이 무언가를 묻는다(이미 그 위였다면 안 뛰는
            // 것이 정답이다). 그리고 누른 뒤에는 그 자리가 thumb 안이어야 한다.
            jump_judgeable and !jump_on_thumb_before and jump_on_thumb_after and
                jump_col_after != jump_col_before,
        });
        try stdout.print("wheel_axes: col {d}->{d} line {d}->{d} axes_ok={}\n", .{
            axis_col_before,
            axis_col_after,
            axis_line_before,
            axis_line_after,
            // **둘 다 안 움직여야 한다** — 40 도 80 도 한 눈금이 아니다. 나머지를 나눠 쓰면
            // 120 이 되어 세로가 한 눈금 굴러간다.
            axis_judgeable and axis_col_after == axis_col_before and axis_line_after == axis_line_before,
        });
        try stdout.print("term_hwheel: scrolls {d}->{d} reports {d}->{d} term_hwheel_ok={}\n", .{
            hterm_scrolls_before,
            hterm_scrolls_after,
            hterm_reports_before,
            hterm_reports_after,
            // **살아서 여기까지 온 것**이 절반이고(패닉이면 이 줄이 안 찍힌다), 나머지 절반은
            // 세로가 대신 굴러가지 않았다는 것이다.
            hterm_judgeable and hterm_scrolls_after == hterm_scrolls_before and
                hterm_reports_after == hterm_reports_before,
        });
        try stdout.print("editor_hdrag: col {d}->{d} thumb {d:.1}->{d:.1} drags={d} hdrag_ok={}\n", .{
            hdrag_col_before,
            hdrag_col_after,
            hdrag_thumb_before,
            hdrag_thumb_after,
            hdrag_drags,
            // **끌린 자리와 그려진 막대가 같이 움직였는가.** 값만 움직이고 막대가 제자리면 사용자는
            // 자기가 무엇을 잡고 있는지 못 본다.
            hdrag_judgeable and hdrag_col_after > hdrag_col_before and hdrag_thumb_after > hdrag_thumb_before,
        });
        try stdout.print("editor_hoob: col={d} hmax={d} cells={d} hoob_ok={}\n", .{
            hoob_col_after,
            hoob_hmax,
            hoob_cells,
            // **판이 통째로 비지는 않았는가**까지 본다 — 값만 되돌리고 화면이 비면 고친 것이 아니다.
            // (줄 번호까지 포함한 수다 — 본문이 몇 글자 남았는지까지는 이 값으로 못 잰다.)
            hoob_judgeable and hoob_hmax > 0 and hoob_col_after == hoob_hmax and hoob_cells > 0,
        });
    }
    if (scroll_judgeable) {
        try stdout.print("editor_scroll: first {d}->{d} scrolls={d} digest {x}->{x} editor_scroll_ok={}\n", .{
            scroll_first_before,
            scroll_first_after,
            editor_scrolls,
            scroll_digest_before,
            scroll_digest_after,
            scroll_first_after > scroll_first_before and scroll_digest_after != scroll_digest_before,
        });
    } else {
        try stdout.print("editor_scroll=unjudgeable reason=no_file_active\n", .{});
    }
    if (md_judgeable) {
        // **거절을 세는 것만으로는 모자란다** — 거절했다고 적으면서 열었을 수도 있다. 목록이
        // 안 늘었는지를 함께 본다.
        try stdout.print("open_md: files {d}->{d} rejects {d}->{d} reason={s} md_not_opened={}\n", .{
            md_files_before,
            md_files_after,
            md_rejects_before,
            md_rejects_after,
            OpenOutcome.name(md_reason),
            // **이유까지 본다.** 거절 수만 세면 읽기가 깨져서 못 연 것도 "계약대로 안 열었다" 로
            // 초록이 된다 — `.md` 는 반드시 `needs_web_panel` 이어야 한다.
            md_files_before == md_files_after and md_rejects_after > md_rejects_before and md_reason == .needs_web_panel,
        });
    } else {
        try stdout.print("open_md=unjudgeable reason=no_md_row_visible\n", .{});
    }
    if (ag_refresh_judgeable) {
        // **제출과 반영을 갈라 센다.** 인텐트가 왔다는 것만으로는 다시 훑었다고 못 한다.
        try stdout.print("agent_refresh: submits={d} applies {d}->{d} cards={d} agent_refresh_ok={}\n", .{
            agent_refresh_submits,
            ag_refresh_applies_before,
            agent_applies,
            agent_archive.cards.len,
            agent_refresh_submits > 0 and agent_applies > ag_refresh_applies_before and agent_archive.cards.len > 0,
        });
    }
    if (ag_sort_judgeable) {
        // **목록이 실제로 뒤집혔는가**와 **라벨이 따라왔는가**를 함께 본다.
        try stdout.print("agent_sort: first {d}->{d} oldest_first={} agent_sort_ok={}\n", .{
            ag_sort_first_before,
            ag_sort_first_after,
            ag_sort_order_after,
            ag_sort_first_after != ag_sort_first_before and ag_sort_order_after,
        });
    } else {
        // **사유가 정확해야 한다** — 좁아서 없는 것과 눌러도 안 되는 것은 다른 사실이다.
        try stdout.print("agent_sort=unjudgeable reason=header_too_narrow dock_w={d}\n", .{geom.dock.w});
    }
    if (ag_hover_judgeable) {
        // **다시 그리되 아무 일도 하면 안 된다** — 이동이 인텐트를 내면 스치기만 해도 목록이 바뀐다.
        try stdout.print("agent_hover: redraws {d}->{d} intents {d}->{d} agent_hover_ok={}\n", .{
            ag_hover_redraws_before,
            ag_hover_redraws_after,
            ag_hover_intents_before,
            ag_hover_intents_after,
            ag_hover_redraws_after > ag_hover_redraws_before and
                ag_hover_intents_after == ag_hover_intents_before,
        });
    } else {
        try stdout.print("agent_hover=unjudgeable reason=no_card\n", .{});
    }
    if (max_judgeable) {
        // **바닥에 닿아야 한다.** 반올림 한 픽셀은 봐준다 — 그보다 벌어지면 마지막 항목이 영영
        // 안 보인다는 뜻이다.
        try stdout.print("bar_bottom: gap={d:.1} bar_max={d} wheel_max={d} bar_extent_ok={}\n", .{
            bottom_gap,
            bar_max,
            wheel_max,
            @abs(bottom_gap) <= 1.0 and bar_max == wheel_max and bar_max > 0,
        });
    } else {
        try stdout.print("bar_bottom=unjudgeable reason=no_bar\n", .{});
    }
    if (fits_judgeable) {
        try stdout.print("bar_when_fits: quads={d} ok={}\n", .{ fits_bar_quads, fits_bar_quads == 0 });
    } else {
        try stdout.print("bar_when_fits=unjudgeable reason=already_overflowing\n", .{});
    }
    if (after_release_judgeable) {
        try stdout.print("bar_after_release: sb {d}->{d} dock {d}->{d} ok={}\n", .{
            after_release_before,
            after_release_after,
            after_release_dock_before,
            after_release_dock_after,
            after_release_after == after_release_before and after_release_dock_after == after_release_dock_before,
        });
    } else {
        try stdout.print("bar_after_release=unjudgeable reason=no_bar\n", .{});
    }
    if (sb_track_judgeable) {
        // 트랙 위쪽(맨 위 근처)을 눌렀으니 **위로** 가야 한다.
        try stdout.print("sb_track: off {d}->{d} clicks={d} sb_track_ok={}\n", .{
            sb_track_before,
            sb_track_after,
            bar_track_clicks,
            bar_track_clicks > 0 and sb_track_after < sb_track_before,
        });
    } else {
        try stdout.print("sb_track=unjudgeable reason=no_bar\n", .{});
    }
    try stdout.print("sidebar_w={d} sidebar_cells={d} sidebar_glyphs={d} sidebar_cells_outside={d} card_over_header={d} cards_visible={d}/{d} term_x={d}\n", .{ sidebar_w, sidebar_cells.items.len, sidebar_glyphs, sidebar_outside, sidebar_card_over_header, sidebar_cards_visible, sidebar_cards.items.len, geom.terminal.x });
    {
        // **"다시 그렸다" 와 "보이게 달라졌다" 는 다르다.** 처음에 `tab_hover_bg` 를 썼더니 스모크는
        // `sidebar_redraws=2` 로 초록인데 화면은 그대로였다 — 그 role 은 배경↔활성 **중간**이라
        // 활성 카드 위에서 **더 어둡다**(토큰 문서가 그 함정을 이미 적어 뒀고, 캡처가 그것을 확인했다).
        //
        // 규칙을 그대로 잰다: **호버는 활성보다 밝다.** 두 값은 테마가 주므로 내 코드를 되읽는 것이
        // 아니다 — 테마를 바꿔도 이 성질이 남아야 한다.
        const a = chrome_tokens.get(.tab_active_bg);
        const hv = chrome_tokens.get(.row_hover_bg);
        const lum_a: u32 = @as(u32, a.r) * 299 + @as(u32, a.g) * 587 + @as(u32, a.b) * 114;
        const lum_h: u32 = @as(u32, hv.r) * 299 + @as(u32, hv.g) * 587 + @as(u32, hv.b) * 114;
        try stdout.print("card_active=#{x:0>2}{x:0>2}{x:0>2} card_hover=#{x:0>2}{x:0>2}{x:0>2} hover_is_brighter={}\n", .{
            a.r, a.g, a.b, hv.r, hv.g, hv.b, lum_h > lum_a,
        });
    }
    if (sidebar_scroll_judgeable) {
        // **그린 첫 카드는 빌더가**(`snap_first_visible`), **눌린 카드는 클릭이 지나간 호출부가**
        // 낸다. 판정이 어느 한쪽을 다시 계산하면 그쪽 배선이 끊겨도 안 잡힌다 — 도크에서 그 함정을
        // 두 번 밟았다(§2m.52).
        const max_scroll: u32 = snap_content_h -| snap_view_h;
        // **그린 자리와 누른 자리가 함께 틀리면 서로는 맞는다.** 그리기가 스크롤을 통째로 무시한
        // 뮤턴트가 그렇게 통과했다 — 둘 다 0 이면 일치한다. 그래서 **세 번째 눈**을 둔다: 중립
        // `rowTop` 이 말하는 그 카드의 y 와 우리가 실제로 그린 밴드 y 를 견준다. `rowTop` 은 우리
        // 누적을 안 쓰므로 그리기만 어긋나도 갈린다.
        const want_band_y: i64 = snap_want_band_y;
        const band_matches = @abs(@as(i64, snap_first_band_y) - want_band_y) <= 1;
        // **활성 표시가 옳은 카드에 있는가.** 창 좌표로 안 옮기면 굴린 뒤 엉뚱한 카드에 앰버 막대가
        // 선다 — 개수·자리 판정은 그것을 전혀 안 본다.
        const want_active_y: i64 = snap_want_active_y;
        // **공허하지 않게 한다.** 활성 카드가 창 안이면 **반드시 그려져야** 하고 자리도 맞아야
        // 한다. 처음에는 `null` 이면 참으로 뒀는데, 활성 카드가 화면 밖이라 그 검사가 통째로
        // 건너뛰어졌다 — 앰버 막대를 엉뚱한 카드에 그리는 뮤턴트가 그대로 통과했다.
        // **`app_window.active_tab` 이 아니라 그때 그린 슬롯이다.** 파일이 활성이면 둘이 다르다.
        const active_in_window = snap_active_slot >= snap_first_visible and
            snap_active_slot < snap_first_visible + snap_cards_visible;
        const active_ok = if (active_in_window)
            snap_active_band_y != null and @abs(@as(i64, snap_active_band_y.?) - want_active_y) <= 1
        else
            snap_active_band_y == null;
        try stdout.print("sidebar_scrolls={d} snap_scroll_px={d}/{d} first_visible={d} clicked_slot={?d} band_y={d} want_band_y={d} band_matches={} partial={d} active_ok={} names_view={} over_header={d} sidebar_scroll_ok={}\n", .{
            sidebar_scrolls,
            snap_scroll_px,
            max_scroll,
            snap_first_visible,
            sidebar_scroll_clicked_slot,
            snap_first_band_y,
            want_band_y,
            band_matches,
            snap_partial,
            active_ok,
            snap_active_names_view,
            snap_over_header,
            sidebar_scrolls > 0 and snap_scroll_px > 0 and snap_scroll_px <= max_scroll and
                sidebar_scroll_click_sent and sidebar_scroll_clicked_slot != null and
                sidebar_scroll_clicked_slot.? == snap_first_visible and
                band_matches and active_ok and snap_active_names_view and snap_over_header == 0,
        });
    } else {
        try stdout.print("sidebar_scroll=unjudgeable reason=content_fits cards={d}\n", .{sidebar_cards.items.len});
    }
    if (sidebar_judgeable) {
        // **동어반복이 아니다**: 카드 한복판을 누른 것은 맞지만, 그 y 를 슬롯으로 되돌리는 것은
        // 중립 `slotAt` 이고 그것은 내 좌표를 모른다. 헤더 쪽도 마찬가지로 `headerHit` 이 답한다.
        // 그리고 **hover 로 그림이 실제로 다시 그려졌는지**(`redraws`)를 함께 적는다 — 안 그러면
        // "눌리긴 하는데 화면이 그대로" 를 못 가른다(§2m.35 가 겪은 실패).
        try stdout.print("sidebar_pointer_events={d} sidebar_redraws={d} card_clicks={d} last_slot={?d} header_clicks={d} last_header={s} sidebar_click_ok={}\n", .{
            sidebar_pointer_events,
            a3_redraws,
            a3_card_clicks,
            a3_card_slot,
            a3_header_clicks,
            if (a3_header) |h| @tagName(h) else "none",
            // **그 순간의 답만 본다** — 뒤에 오는 시험들이 같은 변수를 덮는다.
            a3_card_clicks >= 1 and a3_card_slot != null and a3_card_slot.? == 0 and
                a3_header_clicks >= 1 and a3_header == .new_workspace and a3_redraws > 0 and
                hoverIsBrighter(&chrome_tokens),
        });
    } else {
        try stdout.print("sidebar_click=unjudgeable reason=no_sidebar_or_header sidebar_w={d} header_h={d}\n", .{ sidebar_w, sidebar_header_h });
    }
    // **모든 세션이 지금 창 크기를 안다.** 활성만 리사이즈하면 배경 세션은 옛 격자를 들고 있다가
    // 전환하는 순간 어긋난 화면을 낸다. 새로 만든 세션도 **그때의** 크기를 받아야 한다.
    {
        const want = if (app_window.active()) |a| a.core.size else start;
        var wrong: usize = 0;
        for (sessions.items) |s| {
            const sz = s.surface.core.size;
            if (sz.cols != want.cols or sz.rows != want.rows) wrong += 1;
        }
        try stdout.print("session_grid_want={d}x{d} sessions_wrong_size={d}\n", .{ want.cols, want.rows, wrong });
    }
    // ── 세션·전환 판정 (W8.8⒞) ──────────────────────────────────────────────────────────────
    // **카드 수 == 세션 수 + 연 파일 수, 그리고 탭 수 == 세션 수.** 셋이 갈리면 사이드바가 목록을
    // 거짓말하고, `slotAt` 이 없는 카드를 가리키거나 있는 세션을 못 가리킨다. 갱신을 빼먹은
    // 뮤턴트가 **다른 판정 전부를 통과**했다(실측: `cards=1 sessions=2` 인데 `switch_ok=true`).
    //
    // **전제가 바뀐 자리다.** W8.13 전에는 `cards == tabs` 였는데 파일이 카드로 붙으면서 그것이
    // 깨졌다(실측 `cards=14 tabs=13`). 판정을 **끄지 않고** 참인 불변식으로 고쳤다 — 끄면 그 뒤로
    // 목록이 어긋나도 아무 말이 없다.
    try stdout.print("sessions={d} spawns={d} spawn_failures={d} tab_switches={d} cards={d} tabs={d} open_files={d} lists_agree={}\n", .{
        sessions.items.len,
        session_spawns,
        session_spawn_failures,
        tab_switches,
        sidebar_cards.items.len,
        app_window.tabs.len,
        open_files.items.len,
        sidebar_cards.items.len == sessions.items.len + open_files.items.len and app_window.tabs.len == sessions.items.len,
    });
    if (switch_judgeable) {
        // **동어반복을 피한다.** `active_tab` 이 바뀐 것만 보면 내가 부른 `selectTab` 을 되읽는
        // 것이다. 두 세션의 셸이 각자 프롬프트를 찍으므로 **격자 지문**이 달라야 한다 — 그것이
        // "화면이 실제로 그 세션을 보고 있다" 의 증거다.
        try stdout.print("switch_before_tab={d} switch_after_tab={d} active_matches_selected={} background_ink={d} switch_ok={}\n", .{
            active_before_switch,
            app_window.active_tab,
            active_matches_selected,
            background_ink,
            app_window.active_tab != active_before_switch and
                active_matches_selected and background_ink > 0 and
                sessions.items.len > 1,
        });
    } else {
        try stdout.print("session_switch=unjudgeable reason=single_session sessions={d}\n", .{sessions.items.len});
    }
    // ── 사이드바 헤더 판정 (W8.8⒝) ─────────────────────────────────────────────────────────
    //
    // **개수만 세면 속 빈다** — 네 글리프가 다 나와도 자리가 틀리면 화면에서만 보인다(§2m.42 가
    // 그렇게 당했다). 그래서 **그린 열의 픽셀 중앙을 `headerHit` 에 되먹여** 그 아이콘의 영역이
    // 나오는지 본다. 동어반복이 아니다: 그리기는 `headerIconCol`, 판정은 `headerHit` 이고 둘은
    // 서로를 안 부른다 — 어느 한쪽만 바뀌면 여기서 갈린다.
    if (sidebar_header_h != 0) {
        const sb_h = maru.chrome.components.sidebar;
        // **그린 자리를 읽는다.** 앞선 판은 기대 열을 `headerIconCol` 로 만들어 그것을 다시
        // `headerHit` 에 넣었는데, 그러면 그리기 쪽만 어긋나도 안 잡힌다 — 실제로 열을 하나 옮긴
        // 뮤턴트가 `4/4` 로 통과했다. 이제 **정체는 codepoint, 자리는 그려진 열**에서 온다.
        var routed: usize = 0;
        for (sidebar_header_drawn.slice()) |g| {
            const want: sb_h.HeaderRegion = if (g.codepoint == maru.icons.codepoint(.bell))
                .notifications
            else if (g.codepoint == maru.cell_text.sidebar_toggle_codepoint)
                .toggle_sidebar
            else if (g.codepoint == maru.icons.codepoint(.gear))
                .view_options
            else if (g.codepoint == maru.icons.codepoint(.plus))
                .new_workspace
            else
                continue; // 배지 숫자 같은 비-아이콘 셀은 이 판정의 대상이 아니다
            const x: f64 = (@as(f64, @floatFromInt(g.col)) + 0.5) * @as(f64, @floatFromInt(cell_w));
            // **아이콘 줄의 중앙을 찌른다** — 헤더 한복판은 이제 검색 밴드다.
            const y: f64 = @as(f64, @floatFromInt(sidebar_header_icon_band)) * 0.5;
            if (sb_h.headerHit(x, y, sidebar_w, cell_w, cell_h, sidebar_header_h, sidebar_header_icon_band) == want) routed += 1;
        }
        // **검색 밴드도 잰다** — 그 줄을 그렸으니 눌려야 한다(안 그렸으면 `.search` 가 나오면 안 된다).
        const search_y: f64 = @as(f64, @floatFromInt(sidebar_header_icon_band + sidebar_header_h)) * 0.5;
        // **그렸는가와 눌리는가를 함께 본다.** 히트테스트만 물으면 아무것도 안 그려도 참이다 —
        // 실측: 검색 줄을 통째로 지워도 이 값이 `true` 였고, 잡은 것은 매직넘버 쪽이었다.
        const search_routes = sb_h.headerHit(
            @as(f64, @floatFromInt(sidebar_w)) * 0.5,
            search_y,
            sidebar_w,
            cell_w,
            cell_h,
            sidebar_header_h,
            sidebar_header_icon_band,
        ) == .search;
        // 🔍 한 칸 + placeholder 글자들. 하나라도 없으면 "검색이 여기 있다" 는 표시가 아니다.
        const search_ok = search_routes and sidebar_header_search_glyphs >= 2;
        // **선명한가**를 숫자로 본다. 구운 높이(아틀라스)와 그린 높이(quad)가 **둘 다** 셀보다 커야
        // 1.7× 텍스처가 1.7× 사각형에 1:1 로 들어간다 — 하나만 크면 늘리거나 눌러서 흐려진다.
        var sharp: usize = 0;
        // **가로세로 비가 같아야 한다.** 구운 그림과 그린 사각형의 종횡비가 다르면 늘어나거나
        // 눌려서 보인다 — 그것이 "찌그러진 종" 이었고, 높이만 보던 판정은 그때도 초록이었다.
        var undistorted: usize = 0;
        // **아이콘 줄이 창 버튼과 같은 줄인가.** 이것만이 그것을 본다 — 띠 아래에 그려지고 있는
        // 동안에도 위 판정들은 **전부 초록**이었다(개수·선명도·종횡비는 자리를 안 본다). 사용자가
        // 화면에서 지적했고(2026-08-25), 그 뒤 픽셀을 세어 확인했다.
        var in_strip: usize = 0;
        // **그리고 그 위에 덮이지 않았는가.** 띠 채움은 사이드바 셀 **뒤에** 그려지므로, 전폭을
        // 칠하면 아이콘이 통째로 사라진다 — 그런데 `icons_in_strip` 은 그것을 **못 본다**(그리기
        // 목록을 보지 다 그린 픽셀을 안 본다). 실제로 그 결함이 났고 픽셀을 세어서야 드러났다.
        // 그래서 **두 목록을 견준다**: 띠 채움 사각형과 아이콘 quad 가 겹치면 덮인 것이다.
        var uncovered: usize = 0;
        const fill: ?[4]f32 = if (titlebar_cells.items.len == 0) null else titlebar_cells.items[0].rect;
        for (sidebar_header_drawn.slice()) |g| {
            if (g.quad_h > 0 and g.quad_y >= 0 and g.quad_y + g.quad_h <= @as(f32, @floatFromInt(titlebar_px))) in_strip += 1;
            if (g.quad_w <= 0 or g.quad_h <= 0) continue;
            const gx: f32 = @floatFromInt(@as(u32, g.col) *| cell_w);
            const f = fill orelse {
                uncovered += 1;
                continue;
            };
            const overlap = gx < f[0] + f[2] and gx + g.quad_w > f[0] and
                g.quad_y < f[1] + f[3] and g.quad_y + g.quad_h > f[1];
            if (!overlap) uncovered += 1;
        }
        for (sidebar_header_drawn.slice()) |g| {
            if (g.atlas_h > cell_h and g.quad_h > @as(f32, @floatFromInt(cell_h))) sharp += 1;
            if (g.atlas_w == 0 or g.atlas_h == 0 or g.quad_h <= 0) continue;
            const want = @as(f32, @floatFromInt(g.atlas_w)) / @as(f32, @floatFromInt(g.atlas_h));
            const got = g.quad_w / g.quad_h;
            // 픽셀 반올림 여유. 두 배 벌어지는 찌그러짐과는 자릿수가 다르다.
            if (@abs(got - want) <= 0.15) undistorted += 1;
        }
        try stdout.print("sidebar_header_h={d} icon_band={d} icon_glyphs={d} search_glyphs={d} header_outside={d} header_routed={d}/4 search_drawn_and_hit={} icons_sharp={d}/4 icons_undistorted={d}/4 icons_in_strip={d}/4 icons_uncovered={d}/4 header_ok={}\n", .{
            sidebar_header_h,
            sidebar_header_icon_band,
            sidebar_header_icon_glyphs,
            sidebar_header_search_glyphs,
            sidebar_header_outside,
            routed,
            search_ok,
            sharp,
            undistorted,
            in_strip,
            uncovered,
            sidebar_header_icon_glyphs == 4 and sidebar_header_outside == 0 and routed == 4 and search_ok and sharp == 4 and undistorted == 4 and in_strip == 4 and uncovered == 4,
        });
    } else {
        // **판정 불가와 실패를 가른다** — 헤더를 안 그린 것을 0 으로만 적으면 고장으로 읽힌다.
        // **사유가 맞아야 쓸모가 있다**: 좁아서인지 낮아서인지 구별 안 하면 엉뚱한 데를 뒤진다
        // (실측: 낮아서 못 그린 경우에 "too_narrow" 라고 적고 있었다).
        const hcols = sidebar_w / cell_w;
        const reason: []const u8 = if (sidebar_w == 0)
            "no_sidebar"
        else if (hcols < maru.cell_text.sidebar_header_min_cols)
            "too_narrow"
        else
            "too_short";
        try stdout.print("sidebar_header=unjudgeable reason={s} cols={d} min_cols={d} avail_h={d} need_h={d}\n", .{
            reason,
            hcols,
            maru.cell_text.sidebar_header_min_cols,
            geom.workspace.h,
            cell_h *| 3,
        });
    }
    // ── 뷰 바 아이콘 세로 정렬 (사용자 지적 2026-08-25) ────────────────────────────────────
    //
    // **셀 행으로만 보면 못 잡는다.** 중립은 자리를 행으로 말하고 `rows / 2` 가 최선인데, 바가
    // **짝수 줄**이면 그것이 **아래 줄**이라 아이콘이 바닥에 붙는다. 반 줄은 격자로 못 적으므로
    // 픽셀에서 잰다 — 글리프 위 여백과 아래 여백이 같아야 한다.
    if (view_bar_glyph_top) |top| {
        const want: f32 = @as(f32, @floatFromInt(geom.view_bar.y)) +
            (@as(f32, @floatFromInt(geom.view_bar.h)) - @as(f32, @floatFromInt(cell_h))) / 2;
        try stdout.print("view_bar_h={d} glyph_top={d:.0} want_top={d:.0} view_bar_centered={}\n", .{
            geom.view_bar.h,
            top,
            want,
            @abs(top - want) <= 1,
        });
    } else {
        try stdout.print("view_bar=unjudgeable reason=no_glyphs h={d}\n", .{geom.view_bar.h});
    }
    try stdout.print("dock_scan_ok={} dock_rows={d} dock_region_uploads={d} dock_tree_frame={} dock_cells_outside={d} dock_rows_drawn={d}\n", .{ dock_scan_ok, dock_rows.items.len, dock_region_uploads, dock_tree_frame != null, dock_cells_outside, dock_rows_drawn });
    const agent_keep_kb = agent_arena.queryCapacity() / 1024;
    if (agent_judgeable) {
        // **개수만 세면 속 빈다** — 조립이 실패해도 셀이 0 이고, 목록이 비어도 0 에 가깝다.
        // 그래서 **글자가 나왔는가**를 함께 본다: 헤더·검색·빈 안내는 목록과 무관하게 그려진다.
        try stdout.print("agent_view={} agent_ops={d} agent_ops_dropped={d} agent_cells={d} agent_glyph_bytes={d} agent_items={d} agent_groups={d} agent_cards={d} agent_titles_drawn={d} agent_list={s} agent_raster_err={d} agent_scan_kb={d} agent_keep_kb={d} agent_slot=({d},{d}) agent_ok={}\n", .{
            agent_view_reached,
            agent_ops,
            agent_ops_dropped,
            agent_cells,
            agent_glyph_bytes,
            agent_items.items.len,
            agent_groups,
            agent_cards,
            agent_titles_drawn,
            if (agent_list_reason.len == 0) "ok" else agent_list_reason,
            agent_raster_err,
            agent_scan_kb,
            agent_keep_kb,
            agent_slot_x,
            agent_slot_y,
            agent_view_reached and agent_ops > 0 and agent_cells > 0 and agent_glyph_bytes > 0 and
                // **목록이 있다고 말했으면 카드가 있어야 한다.** `titles_drawn == cards` 만
                // 보면 0 == 0 이 참이라, 목록을 표면에 안 넘기는 퇴행이 그대로 통과한다(실측:
                // 그 뮤턴트가 이 자리를 빠져나갔다). 이력이 없는 기계는 `agent_list` 가 그
                // 사실을 말하므로 **그때만** 0 을 받아들인다.
                //
                // **그리고 모든 이유가 정상 상태는 아니다.** `no_history`·`no_home` 은 그 기계의
                // 사실이지만 `scan_timeout`·`scan_failed` 는 **데이터 경로가 깨진 것**이다 — 둘을
                // 한 덩어리로 봐주면 상한에 걸린 회귀가 초록으로 지나간다(실측: 상한을 0 으로
                // 만든 뮤턴트가 `ok=true` 로 통과했다).
                agentListBenign(agent_list_reason) and
                (agent_list_reason.len != 0 or agent_cards > 0) and
                agent_titles_drawn == agent_cards and
                // **1 MB 경계.** 남는 것은 카드 수에 비례하지(카드당 문자열 몇 개) 이력 크기에
                // 비례하지 않는다 — 실측 카드 11 장에 7 KB 다. 수백 장이어도 이 안이고, arena 를
                // 도로 합치면 **43 MB** 로 튄다(뮤턴트 실측). 그 사이에 경계를 둔다.
                agent_keep_kb < 1024 and agent_raster_err == 0,
        });
    } else {
        try stdout.print("agent=unjudgeable reason=no_view_bar\n", .{});
    }
    if (expand_judgeable) {
        // **동어반복이 아니다**: 토글 횟수를 되읽는 것이 아니라 **행 목록의 길이**를 본다 — 펼치면
        // 자식이 들어와 늘고, 접으면 되돌아온다. 그 사이에 스캔·행 재구성이 전부 일어나야 한다.
        try stdout.print("expand_row={d} rows_before={d} rows_after={d} rows_collapsed={d} toggles={d} expand_ok={}\n", .{
            expand_row,
            expand_rows_before,
            expand_rows_after,
            expand_rows_collapsed,
            dock_row_toggles,
            expand_rows_after > expand_rows_before and expand_rows_collapsed == expand_rows_before and dock_row_toggles >= 2,
        });
    } else {
        try stdout.print("expand=unjudgeable reason=no_collapsed_directory rows={d}\n", .{dock_rows.items.len});
    }
    if (dock_scroll_judgeable) {
        // **동어반복이 아니다**: 스크롤 값을 되읽는 것이 아니라, 뷰포트 맨 위를 `rowAtLocalY` 에
        // 넣어 나온 행이 `drawWindow` 가 **실제로 그린 첫 행**과 같은지 본다. 두 함수는 서로를
        // 안 부르고, 하나만 어긋나면 여기서 갈린다.
        // **그린 첫 행**은 `drawWindow` 가, **눌린 행**은 실제 클릭이 지나간 호출부가 낸다.
        // 둘은 서로를 안 부른다 — 하나만 어긋나면 여기서 갈린다.
        // **셋이 서로 다른 곳에서 온다.** 그린 첫 행은 **빌더가 실제로 쓴 값**(`dock_draw_start`),
        // 눌린 행은 클릭이 지나간 호출부, 상한은 콘텐츠 높이다. 어느 하나를 판정이 다시 계산하면
        // 그쪽 배선이 끊겨도 안 잡힌다 — 이 판정이 두 번 그렇게 속았다.
        const content_h: u32 = @intCast(dock_rows.items.len *| cell_h);
        const max_scroll: u32 = content_h -| geom.tree_content.h;
        const within = dock_scroll_px <= max_scroll;
        // **부분 스크롤이 픽셀로 갔는가.** 첫 행은 뷰포트 위로 `shift` 만큼 밀려야 한다 — 안 밀면
        // 스크롤이 행 단위로만 움직인다(그때도 개수·행 판정은 전부 초록이었다).
        const want_top: f32 = @as(f32, @floatFromInt(geom.tree_content.y)) - @as(f32, @floatFromInt(dock_scroll_shift));
        const shift_applied = dock_tree_top_px != null and @abs(dock_tree_top_px.? - want_top) < 1.0;
        try stdout.print("dock_scrolls={d} dock_scroll_px={d}/{d} dock_shift={d} draw_start={d} clicked_row={?d} within_max={} shift_applied={} dock_scroll_ok={}\n", .{
            dock_scrolls,
            dock_scroll_px,
            max_scroll,
            dock_scroll_shift,
            dock_draw_start,
            dock_scroll_clicked_row,
            within,
            shift_applied,
            dock_scrolls > 0 and dock_scroll_px > 0 and dock_scroll_click_sent and within and shift_applied and
                dock_scroll_clicked_row != null and dock_scroll_clicked_row.? == dock_draw_start,
        });
    } else {
        // **판정 불가 사유가 맞아야 한다.** 굴릴 것이 없는 것과 도크가 없는 것은 다른 사실이다.
        const content_h: u32 = @intCast(dock_rows.items.len *| cell_h);
        // **사유가 지금 숫자와 맞아야 한다.** 이 판정은 앞선 순간에 "안 넘친다" 로 접히는데, 그
        // 뒤 스크롤바 시험이 폴더를 펼쳐 목록을 늘린다 — 그때 `content_fits` 라고 적으면서 넘치는
        // 숫자를 함께 찍게 된다(실측 2026-08-26: `content_h=570 viewport_h=537` 인데 "fits").
        // 사유를 **찍는 값에서** 유도하면 그 어긋남이 생기지 않는다.
        const why: []const u8 = if (geom.tree_content.w == 0)
            "no_dock"
        else if (content_h > geom.tree_content.h)
            "not_scrolled"
        else
            "content_fits";
        try stdout.print("dock_scroll=unjudgeable reason={s} rows={d} content_h={d} viewport_h={d}\n", .{ why, dock_rows.items.len, content_h, geom.tree_content.h });
    }
    if (dock_click_judgeable) {
        // **동어반복을 피한다**: 누른 자리가 그 행이라는 것만 보면 내가 만든 좌표를 내가 되읽는
        // 것이다. 그 행의 **이름**을 모델에서 꺼내 함께 적어, 화면에 뜬 목록과 대조할 수 있게 한다.
        const name: []const u8 = if (dock_click_name_len > 0) dock_click_name_buf[0..dock_click_name_len] else if (dock_last_row) |r| blk: {
            if (r >= dock_rows.items.len) break :blk "<out-of-range>";
            break :blk switch (dock_rows.items[r]) {
                .root => |x| x.label,
                .directory => |x| x.label,
                .file, .recent_file => |x| x.label,
                .recent_header => "<recent-header>",
                .empty => "<empty>",
            };
        } else "<none>";
        try stdout.print("dock_pointer_events={d} dock_row_clicks={d} dock_last_row={?d} want_row={d} row_name={s}\n", .{ dock_pointer_events, dock_row_clicks, dock_click_answer, dock_click_target_row, name });
    } else {
        try stdout.print("dock_click=unjudgeable reason=no_dock_or_too_few_rows dock_pointer_events={d}\n", .{dock_pointer_events});
    }
    // **서로 안 샌다**: 도크 클릭 뒤에도 셸 선택은 그대로였고(그 시점 값이 `selections_before_term_click`),
    // 터미널 클릭은 도크 카운터를 안 올렸다.
    if (view_judgeable) {
        const after = d3d11_cells.cellsDigest(dock_cells.items);
        if (scm_click_judgeable) {
            try stdout.print("scm_dock_intents={d} scm_dock_redraws={d} scm_selected={?d}\n", .{ scm_dock_intents, scm_dock_redraws, scm_state.selected });
        } else {
            try stdout.print("scm_dock_click=unjudgeable reason=no_file_row\n", .{});
        }
        try stdout.print("view_switches={d} dock_view={s} dock_cells={d}->{d} dock_picture_changed={}\n", .{
            view_switches,
            @tagName(dock_view),
            dock_cells_before_switch,
            dock_cells.items.len,
            after != dock_digest_before_switch,
        });
    } else {
        try stdout.print("view_switch=unjudgeable reason=no_view_bar\n", .{});
    }
    if (divider_judgeable) {
        const cols_now = if (app_window.active()) |a| a.core.size.cols else 0;
        // **저장값과 화면이 갈리면 안 된다** — 갈린 채 창을 키우면 도크가 새 공간을 다 먹는다.
        try stdout.print("stored_pt={d} shown_w={d} in_sync={}\n", .{ dock_size_pt, geom.dock.w, dock_size_pt == geom.dock.w });
        try stdout.print("divider_grabs={d} divider_moves={d} dock_w={d}->{d} grid_cols={d}->{d}\n", .{
            divider_grabs,
            divider_moves,
            dock_w_before_drag,
            geom.dock.w,
            grid_cols_before_drag,
            cols_now,
        });
    } else {
        try stdout.print("divider=unjudgeable reason=no_divider\n", .{});
    }
    try stdout.print("selections_at_term_click={d} dock_clicks_at_term_click={d} selections_final={d} dock_clicks_final={d}\n", .{
        selections_before_term_click,
        dock_clicks_before_term_click,
        selections,
        dock_row_clicks,
    });
    const live_grid = if (app_window.active()) |a| a.core.size else maru.terminal.Size{ .cols = 0, .rows = 0 };
    try stdout.print("resizes={d} grid_mismatches={d} dock_rebuild_failures={d} final_grid={d}x{d} final_term_rect={d}x{d}\n", .{
        resizes,
        grid_mismatches,
        dock_rebuild_failures,
        live_grid.cols,
        live_grid.rows,
        geom.terminal.w,
        geom.terminal.h,
    });
    try stdout.print("font_family={s}\n", .{raster.family});
    try stdout.print("cell_px={d}x{d}\n", .{ cell_w, cell_h });
    // **설정이 코어까지 갔는지 값으로 본다.** 색은 화면으로 판정되지만 스크롤백 길이는 안 보인다 —
    // 안 세면 `scrollback.lines` 를 바꿔도 무동작인 것을 못 잡는다(예전이 그랬다).
    try stdout.print("config_runtime: scrollback_cap={d} palette_set={d} cursor_shape={s}\n", .{
        sessions.items[0].surface.core.screen.sb.cap,
        blk: {
            var n: usize = 0;
            for (appearance.theme.palette) |c| {
                if (c != null) n += 1;
            }
            break :blk n;
        },
        @tagName(appearance.cursor.shape),
    });
    try stdout.print("terminal_size={d}x{d}\n", .{ start.cols, start.rows });
    try stdout.print("frames_presented={d}\n", .{frames});
    try stdout.print("cells_drawn_last={d}\n", .{last_cells});
    try stdout.print("atlas_px={d}x{d} resizes={d}\n", .{ atlas_w, atlas_h, atlas_resizes });
    try stdout.print("atlas_region_uploads={d}\n", .{region_uploads});
    // **이 줄이 판정이다** — 올린 슬롯이 actual로 덮은 픽셀. 0이면 글자가 하나도 안 그려졌다.
    try stdout.print("upload_non_clear_pixels={d}\n", .{counts.non_clear_pixels});
    try stdout.print("fallback_glyphs={d} replacement_glyphs={d} raster_skipped={d}\n", .{ counts.fallback, counts.replacement, counts.skipped });
    try stdout.print("keys_to_shell={d} bytes_to_shell={d}\n", .{ keys_to_shell, bytes_to_shell });
    try stdout.print("app_actions={d} keys_ignored={d}\n", .{ app_actions, keys_ignored });
    try stdout.print("preedit_updates={d} failures={d} max_bytes={d} ime_caret_updates={d}\n", .{ preedit_updates, preedit_failures, preedit_max_bytes, ime_caret_updates });
    try stdout.print("pastes={d} paste_bytes={d} bracketed={d} blocked={d} paste_errors={d}\n", .{ paste_out.pastes, paste_out.paste_bytes, paste_out.bracketed, paste_out.blocked, paste_out.errors });
    try stdout.print("copies={d} copy_bytes={d} right_click_pastes={d} right_click_menus_todo={d}\n", .{ copies, copy_bytes, right_click_pastes, right_click_menus_unimplemented });
    // **갈래별로 센다.** 합치면 "이벤트는 왔는데 선택이 안 됐다"를 못 가른다.
    try stdout.print("mouse_events={d} reports={d} selections={d} selection_frames={d} extends={d} words={d} lines={d}\n", .{ mouse_events, mouse_reports, selections, selection_frames, extends, word_selections, line_selections });
    // **이 줄이 판정이다.** 명령을 몇 개 보냈는지가 아니라, 그것이 코어에 **닿아 선택이 생겼는지**를
    // 본다 — 명령 수만 세면 리더가 하나도 적용 못 해도 성공처럼 보인다("성공처럼 보이는 실패").
    {
        const sel: ?[]u8 = if (app_window.active()) |active| blk: {
            active.lockCore(io);
            defer active.unlockCore(io);
            break :blk active.core.extractSelection(allocator) catch null;
        } else null;
        if (sel) |text| {
            defer allocator.free(text);
            try stdout.print("selection_bytes={d}\n", .{text.len});
        } else {
            try stdout.writeAll("selection_bytes=0\n");
        }
    }
    try stdout.print("scrolls={d} alt_scrolls={d} wheel_lines_per_notch={d} double_click_ms={d}\n", .{ scrolls, alt_scrolls, wheel_lines_per_notch, double_click_ms });
    if (last_mouse_cell) |c| {
        try stdout.print("last_mouse_cell={d},{d}\n", .{ c.row, c.col });
    } else try stdout.writeAll("last_mouse_cell=none\n");
    if (last_wheel_cell) |c| {
        try stdout.print("last_wheel_cell={d},{d}\n", .{ c.row, c.col });
    } else try stdout.writeAll("last_wheel_cell=none\n");
    try stdout.print("capture_losses={d} report_commands={d} core_command_drops={d}\n", .{ capture_losses, mouse_report_commands, core_command_drops });
    // **코어가 실제로 무엇을 보고 있는지 찍는다.** 라우팅이 예상과 다를 때 "우리 판정이 틀렸나, 코어가
    // 모드를 못 받았나"를 가르는 유일한 줄이다 — 없으면 둘을 구분 못 해 엉뚱한 곳을 고친다.
    if (app_window.active()) |active| {
        active.lockCore(io);
        const tracking = active.core.mouse_tracking;
        const fmt_mode = active.core.mouse_format;
        const alt = active.core.alt_active;
        const alt_scroll = active.core.alternate_scroll;
        const bracketed = active.core.bracketed_paste;
        active.unlockCore(io);
        try stdout.print("core_modes: mouse_tracking={s} mouse_format={s} alt_active={} alternate_scroll={} bracketed_paste={}\n", .{
            @tagName(tracking), @tagName(fmt_mode), alt, alt_scroll, bracketed,
        });
    }
    try stdout.print("osc52_writes={d} osc52_reads={d} clipboard_errors={d}\n", .{ osc52_writes, osc52_reads, clipboard_errors });
    // **읽기 요청을 갈라 찍는다.** `osc52_reads` 는 정책과 무관하게 오르므로 그것만으로는 "정책이 막았다" 와
    // "정책은 allow 인데 응답 인코더가 없어 못 보냈다" 가 구분되지 않는다 — 후자는 사용자가
    // `osc52.read = allow` 로 켠 뒤에야 나타나고, 조용하면 원인을 못 찾는다.
    try stdout.print("osc52_reads_unanswered_allow={d}\n", .{osc52_reads_denied_unimplemented});
    try stdout.print("shell_ended={}\n", .{ended});
    try stdout.print("swapchain_px={d}x{d} driver={s}\n", .{ present.width_px, present.height_px, @tagName(present.driver) });
    // **어느 ConPTY 를 썼는지 찍는다.** `conpty.dll` 은 `OpenConsole.exe` 를 못 찾으면 시스템 conhost 로
    // **조용히 되돌아간다** — 실패하지 않으므로 이 줄이 없으면 배치가 틀린 것과 잘 된 것을 못 가른다.
    {
        const reason = maru.pty.windowsConptyRejectReason();
        // **config 가 실제로 읽혔는지 찍는다.** 값이 기본값과 같으면 "읽었는데 기본값" 과 "아예 안 읽었다" 를
        // 구분할 수 없다 — 경로와 바인딩 개수를 함께 내면 갈린다.
        try stdout.print("config_bindings: app={d} terminal={d} unbinds={d} rejected={}\n", .{
            loaded.keybindings.len, loaded.terminal_bindings.len, loaded.unbinds.len, binding_config_rejected,
        });
        // `option_as_meta` 도 찍는다 — 리터럴 `false` 로 박혀 있던 자리라, 값이 실제로 흐르는지
        // 눈에 보이지 않으면 같은 실수가 조용히 되살아난다.
        try stdout.print("config_input: paste_protection={} bracketed_safe={} right_click={s} option_as_meta={} word_separators=\"{f}\"\n", .{
            paste_protection, bracketed_paste_is_safe, @tagName(right_click_action), option_as_meta, std.zig.fmtString(default_word_separators),
        });
        try stdout.print("config_osc52_read={s} diagnostics={d}\n", .{ @tagName(osc52_read_policy), loaded.diagnostics.len });
        // **어떤 셸과 인자가 골라졌는지 찍는다.** 리포트에 안 보이면 확인할 방법이 프로세스 트리를
        // 뒤지는 것뿐이었고, 그 상태로 세 키가 배선 없이 오래 남아 있었다(검토 #8). 설정값과 결과를
        // 나란히 찍어 한눈에 어긋남이 보이게 한다.
        try stdout.print("config_shell: windows_shell={s} command=\"{s}\" resolved=\"{s}\" args={d}\n", .{
            @tagName(cfg.shell.windows_shell), cfg.shell.command, command, args.len,
        });
        try stdout.print("conpty={s}{s}{s}\n", .{
            @tagName(maru.pty.windowsConptySource()),
            if (reason.len > 0) " reason=" else "",
            reason,
        });
    }
    try stdout.writeAll("visible UI: real shell output is drawn in the window.\n");
    try stdout.flush();
    try stderr.flush();
}

fn printSmoke(stdout: *std.Io.Writer) !void {
    // 기본 CLI는 의도적으로 작게 둔다. macOS 앱 host가 붙기 전에도
    // `zig build run` 하나로 모듈 그래프가 컴파일되는지 확인하기 위해서다.
    const size = maru.terminal.Size.default;
    try stdout.print("maru: clean-room terminal core scaffold ({d}x{d})\n", .{
        size.cols,
        size.rows,
    });
    // PTY 백엔드가 없는 호스트에서 `demo`를 먼저 권하면 사용자를 실패 경로로 보낸다. 아래 목록의 절반이
    // PTY를 쓰므로 **먼저** 알린다. 판정은 백엔드 선택에서 직접 유도한 값이라(`pty.backend_available`) OS 이름을
    // 다시 비교하지 않고, ConPTY(W4)가 들어오면 저절로 사라진다.
    if (!maru.pty.backend_available) {
        try stdout.writeAll(
            "note: this platform has no PTY backend yet, so `demo` and `app-pty-*` cannot run " ++
                "(docs/plans/windows-platform.md W4 — ConPTY).\n" ++
                "      `app-smoke`, `app-loop-smoke` and `terminfo` still work.\n",
        );
    }
    try stdout.writeAll("run `maru demo` or `zig build demo` for the first runnable PTY slice\n");
    try stdout.writeAll("run `maru app-smoke` or `zig build app-smoke` for the first app-host frame slice\n");
    try stdout.writeAll("run `maru app-loop-smoke` or `zig build app-loop-smoke` for the headless app frame-loop slice\n");
    try stdout.writeAll("run `maru app-pty-loop-smoke` or `zig build app-pty-loop-smoke` for the live PTY frame-loop slice\n");
    try stdout.writeAll("run `maru app-pty-interactive-loop-smoke` or `zig build app-pty-interactive-loop-smoke` for the interactive shell frame-loop slice\n");
    try stdout.writeAll("run `maru app-pty-smoke` or `zig build app-pty-smoke` for the live PTY app-host frame slice\n");
    try stdout.flush();
}

fn runDemo(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    // GUI가 붙기 전에도 actual PTY -> reader -> runtime -> snapshot 경로를 사람이
    // 실행해 볼 수 있어야 한다. 이 demo는 창을 띄우지 않고 같은 runtime 계약을 통과한다.
    const config: maru.app.HeadlessDemoConfig = .{};
    var result = try maru.app.runHeadlessDemo(io, allocator, config);
    defer result.deinit(allocator);

    try stdout.writeAll(result.summary);
    try stdout.writeAll("\n--- screen ---\n");
    try stdout.writeAll(result.screen);
    // artifact 디렉터리는 config가 단일 출처다. 메시지에 경로를 다시 적으면
    // default_artifact_dir이 바뀔 때 안내가 조용히 어긋난다.
    try stdout.print("\nartifacts written to {s}/\n", .{config.artifact_dir});
    try stdout.flush();
}

fn runAppSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    // 아직 actual AppKit/Metal UI를 띄우지 않는다. 이 smoke는 app host가
    // window/surface/runtime/renderer 계약을 한 frame으로 조립하는지 확인한다.
    const config: maru.app.AppSmokeConfig = .{};
    var result = try maru.app.runAppSmoke(io, allocator, config);
    defer result.deinit(allocator);

    try stdout.writeAll(result.summary);
    try stdout.print("\nartifacts written to {s}/\n", .{config.artifact_dir});
    try stdout.writeAll("draw list artifact: app-host.draw-list.txt\n");
    try stdout.writeAll("glyph frame artifact: app-host.glyph-frame.txt\n");
    try stdout.writeAll("visible UI: not yet; this is an app-host contract smoke.\n");
    try stdout.flush();
}

fn runAppLoopSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    // actual NSApplication loop를 붙이기 전에 반복 tick 계약을 먼저 고정한다.
    // 이렇게 해야 native UI가 drain/build/render 순서를 임의로 재구현하지 않는다.
    const config: maru.app.AppFrameLoopSmokeConfig = .{};
    var result = try maru.app.runAppFrameLoopSmoke(io, allocator, config);
    defer result.deinit(allocator);

    try stdout.writeAll(result.summary);
    try stdout.print("\nartifacts written to {s}/\n", .{config.artifact_dir});
    try stdout.writeAll("frame loop artifact: app-loop.frames.txt\n");
    try stdout.writeAll("screen artifact: app-loop.screen.txt\n");
    try stdout.writeAll("visible UI: not yet; this is a deterministic app frame-loop contract smoke.\n");
    try stdout.flush();
}

fn runAppPtyLoopSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    // actual PTY reader thread를 쓰지만 아직 native window loop는 아니다.
    // 이 단계는 AppKit loop가 붙기 전에 PTY event batch마다 FrameLoop가 반복 frame을
    // 만들 수 있는지 확인한다.
    const config: maru.app.AppPtyLoopSmokeConfig = .{};
    var result = try maru.app.runAppPtyLoopSmoke(io, allocator, config);
    defer result.deinit(allocator);

    try stdout.writeAll(result.summary);
    try stdout.print("\nartifacts written to {s}/\n", .{config.artifact_dir});
    try stdout.writeAll("frame loop artifact: app-pty-loop.frames.txt\n");
    try stdout.writeAll("raw PTY artifact: app-pty-loop.raw.txt\n");
    try stdout.writeAll("screen artifact: app-pty-loop.screen.txt\n");
    try stdout.writeAll("snapshot artifact: app-pty-loop.snapshot.txt\n");
    try stdout.writeAll("visible UI: not yet; this is a live PTY frame-loop contract smoke.\n");
    try stdout.flush();
}

fn runAppPtyInteractiveLoopSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    // 이 smoke는 사용자의 actual interactive shell을 실행하지만, 제품 UI는 아직 아니다.
    // 입력은 FrameLoop.handleKeyEvent를 통과해 PTY로 내려가므로, shell과 app input 경계가
    // 같이 검증된다. dotfile/prompt 영향이 있어 기본 check에는 넣지 않는다.
    // 각본은 셸마다 달라 `app/fixture_script.zig`가 단일 출처다 — 표식·인자·입력이 한 곳에 있어야
    // "입력은 POSIX인데 expected값만 고쳤다" 같은 어긋남이 안 생긴다.
    const script = maru.app.fixture_script.interactiveEcho(builtin.os.tag);
    const config: maru.app.AppPtyLoopSmokeConfig = .{
        .artifact_dir = maru.app.pty_loop_smoke.default_interactive_artifact_dir,
        .command = maru.pty.resolveInteractiveShell(),
        .args = script.args,
        .expected_text = maru.app.fixture_script.interactive_marker,
        .interactive_shell = true,
        .scripted_input = script.input,
        .scripted_key_chord = "Cmd+I",
        .max_event_frames = 64,
    };
    var result = try maru.app.runAppPtyLoopSmoke(io, allocator, config);
    defer result.deinit(allocator);

    try stdout.writeAll(result.summary);
    try stdout.print("\nartifacts written to {s}/\n", .{config.artifact_dir});
    try stdout.writeAll("frame loop artifact: app-pty-loop.frames.txt\n");
    try stdout.writeAll("raw PTY artifact: app-pty-loop.raw.txt\n");
    try stdout.writeAll("screen artifact: app-pty-loop.screen.txt\n");
    try stdout.writeAll("snapshot artifact: app-pty-loop.snapshot.txt\n");
    try stdout.writeAll("visible UI: not yet; this is an interactive shell frame-loop contract smoke.\n");
    try stdout.flush();
}

fn runAppPtySmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    // actual PTY output이 app host renderer frame까지 들어가는지 확인한다.
    // 아직 창을 띄우지 않기 때문에 visible UI 확인은 Metal/AppKit smoke가 맡는다.
    const config: maru.app.AppPtySmokeConfig = .{};
    var result = try maru.app.runAppPtySmoke(io, allocator, config);
    defer result.deinit(allocator);

    try stdout.writeAll(result.summary);
    try stdout.print("\nartifacts written to {s}/\n", .{config.artifact_dir});
    try stdout.writeAll("raw PTY artifact: app-pty.raw.txt\n");
    try stdout.writeAll("screen artifact: app-pty.screen.txt\n");
    try stdout.writeAll("snapshot artifact: app-pty.snapshot.txt\n");
    try stdout.writeAll("renderer frame artifact: app-pty.frame.txt\n");
    try stdout.writeAll("visible UI: not yet; this is a live PTY app-host contract smoke.\n");
    try stdout.flush();
}

/// `maru __session-host <session-dir> <socket> <host-id>` — 영속 세션 host 프로세스 본체로 진입한다(P3-d2c/d, §10). 앱 launcher가 detached
/// spawn한 자식이 이 경로를 탄다. macOS 전용(실 socket/fork). non-macOS에서는 daemon 참조를 comptime으로 배제해
/// 컴파일을 보존한다. dir은 socket 경로의 parent이고, host는 SIGTERM(프로세스 종료)까지 accept loop를 돈다.
fn runSessionHostDaemon(io: std.Io, allocator: std.mem.Allocator, args: anytype, stderr: *std.Io.Writer) !void {
    if (builtin.os.tag == .macos) {
        const session_host = @import("platform/macos/session_host.zig");
        var raw_args: [session_host_entrypoint.max_invocation_args][]const u8 = undefined;
        var raw_count: usize = 0;
        while (args.next()) |arg| {
            if (raw_count == raw_args.len) {
                try stderr.writeAll("invalid maru session host invocation: too many arguments\n");
                return error.UnknownCommand;
            }
            raw_args[raw_count] = arg;
            raw_count += 1;
        }
        const invocation = session_host_entrypoint.parse(raw_args[0..raw_count]) catch {
            // daemon/preflight/restore는 서로 다른 strict grammar다. 한 role의 usage를 다른
            // role parse 실패에 출력하지 않고 hidden command 전체의 bounded 오류로 접는다.
            try stderr.writeAll("invalid maru session host invocation\n");
            return error.UnknownCommand;
        };
        switch (invocation) {
            .preflight => {
                session_host.upgrade_bootstrap.runPreflight(
                    allocator,
                    io,
                    session_host_entrypoint.preflight_fd,
                ) catch |err| {
                    try stderr.print("maru session host preflight failed: {s}\n", .{@errorName(err)});
                    return error.UnknownCommand;
                };
                return;
            },
            .restore => |restore| {
                if (!session_host_build_options.allow_validation_only_restore) {
                    var notification_adapter_state: session_host.notification_macos_adapter.State = .{};
                    session_host.restore_activation.runWithNotificationAdapter(
                        allocator,
                        io,
                        restore,
                        notification_adapter_state.adapter(),
                    ) catch |err| {
                        try stderr.print(
                            "maru session host restore activation failed: {s}\n",
                            .{@errorName(err)},
                        );
                        return error.UnknownCommand;
                    };
                    return;
                }
                // Dedicated fixture는 destructive activation 대신 bootstrap
                // compatibility만 확인한다.
                var validated = session_host.upgrade_bootstrap.readRestoreInvocation(
                    allocator,
                    io,
                    restore,
                ) catch |err| {
                    // hidden restore 진입도 실패 이유를 보존해야 upgrade coordinator가 "새 image가
                    // 그냥 종료됐다"와 authority/provenance 거부를 구분할 수 있다. 경로·ID·handoff
                    // 내용은 출력하지 않고 bounded error name만 남긴다.
                    try stderr.print("maru session host restore validation failed: {s}\n", .{@errorName(err)});
                    return error.UnknownCommand;
                };
                validated.deinit();
                return;
            },
            .daemon => |daemon| {
                var startup = session_host.startup_readiness.Notifier.fromEnvironment() catch |err| {
                    try stderr.print("maru session host startup channel failed: {s}\n", .{@errorName(err)});
                    return error.UnknownCommand;
                };
                defer startup.deinit();
                // argv/path allocation부터 poll owner publication까지 어느 실패도 parent를 connect backoff에
                // 남겨 두지 않는다. ready 뒤에는 notifier가 이미 consumed라 이 errdefer는 no-op이다.
                errdefer startup.failed();
                const dir_z = try allocator.dupeZ(u8, daemon.session_dir);
                defer allocator.free(dir_z);
                const socket_z = try allocator.dupeZ(u8, daemon.socket_path);
                defer allocator.free(socket_z);
                var notification_adapter_state: session_host.notification_macos_adapter.State = .{};
                session_host.daemon.runSessionHostWithIdentityStartupAndNotificationAdapter(
                    allocator,
                    io,
                    dir_z,
                    socket_z,
                    daemon.host_id,
                    &startup,
                    notification_adapter_state.adapter(),
                ) catch |err| {
                    try stderr.print("maru {s} failed: {s}\n", .{ session_host_entrypoint.subcommand, @errorName(err) });
                    return error.UnknownCommand;
                };
            },
        }
    } else {
        try stderr.print("maru {s} is macOS-only\n", .{session_host_entrypoint.subcommand});
        return error.UnknownCommand;
    }
}

/// 호스트 OS가 아직 못 하는 CLI 기능. 어느 것이 왜 막혀 있는지를 **한 곳에** 둔다.
const HostGatedFeature = enum {
    /// `maru ssh` — `/bin/sh -c <래퍼 스크립트>`를 execve해 원격에 terminfo를 심고 그 셸이 ssh 세션을 돈다
    /// (끊기면 다시 붙어야 해서 **셸이 남는다** — ssh로 프로세스를 교체하면 다시 붙을 주체가 없다).
    /// Windows에는 `/bin/sh`가 없고 `environ` 심볼도 msvcrt에 없어 **링크가 깨진다**(실측:
    /// `lld-link: undefined symbol: environ`).
    ssh,
    /// `maru install-cli` — `~/.local/bin/maru`에 symlink를 건다. Windows에는 그 관례가 없고, symlink는 개발자
    /// 모드나 관리자 권한을 요구하며, `symlink` 심볼 자체가 msvcrt에 없다(실측: `undefined symbol: symlink`).
    // **W10 이 열었다** — 남겨 두는 이유는 이 enum 이 "무엇이 OS 게이트를 받는가" 의 목록이고,
    // 여기서 지우면 그 사실이 어디에도 안 남는다. `hostGateReason` 이 이제 이 항목에 `null` 을 준다.
    install_cli,
    /// 컨트롤 소켓 — unix domain socket. Windows는 named pipe 이식이 선행이고 `socket`은 ws2_32라 `-lc`로
    /// 링크되지 않는다(실측: `undefined symbol: socket`).
    control_socket,
};

/// 그 기능이 `os_tag`에서 막혀 있으면 **사용자에게 보일 이유**, 아니면 null.
///
/// **OS를 인자로 받는다.** 그래야 테스트가 두 갈래를 모두 돌 수 있다 — 컴파일 타임 분기로 두면 Windows 갈래가
/// 비-Windows CI에서 **공허참**이 되고(이 저장소 CI는 ubuntu·macOS만 돈다), 그 함정은 W1.5 코드 리뷰에서 이미
/// 한 번 밟았다(`path_shape.isDetectableAbsoluteFor`와 같은 규율).
///
/// 셋 다 **지원해야 하는 기능**이고 백로그에 있다 — docs/plans/windows-platform.md의 W9(ssh)·W10(install-cli)과
/// docs/windows-platform.md §8(컨트롤 플레인 transport). 여기서 접는 것은 W2의 목표가 "Windows에서 maru가
/// 빌드·실행된다"이기 때문이고, 접지 않으면 링크가 깨져 그 목표 자체가 성립하지 않는다.
///
/// **호출부는 아래 `gate_*` 상수를 쓴다.** 이 함수를 직접 부르는 것은 테스트뿐이다 — 이유는 그 상수들 위 주석에.
fn hostGateReason(os_tag: std.Target.Os.Tag, feature: HostGatedFeature) ?[]const u8 {
    if (os_tag != .windows) return null;
    return switch (feature) {
        .ssh => "maru ssh is not supported on Windows yet (docs/plans/windows-platform.md W9).",
        // **W10 완료(§2m.62)** — Windows 는 LOCALAPPDATA 아래 maru/bin/maru.cmd 로 설치한다.
        // POSIX 본문과 갈라진 자리는 `runInstallCli` 의 comptime 분기다.
        .install_cli => null,
        // 문구의 단일 출처는 그 게이트를 actual로 강제하는 곳이다 — 접착이 `cli/control_client.zig`로 옮겨 갔으므로
        // 문구도 거기 산다. 여기서 복제하면 둘이 갈려도 아무도 못 잡는다. **`gate`(이 빌드의 comptime 값)가 아니라
        // `gate_reason`(OS 무관 문구)을 쓴다** — 이 함수는 OS를 인자로 받아 두 갈래를 모두 답해야 하기 때문이다.
        .control_socket => maru.cli.control_client.gate_reason,
    };
}

// 이 호스트의 게이트 값. **파일 스코프 const라 comptime으로 평가된다** — 그래서 `if (gate_ssh) |reason|`처럼
// 그냥 쓰면 참인 갈래 뒤의 POSIX 본문이 **의미 분석되지 않고**, `socket`·`environ`·`symlink`가 참조조차 되지
// 않는다(실측: 바이너리에서 그 심볼과 ws2_32 import가 전부 사라진다).
//
// **처음엔 호출부마다 `comptime hostGateReason(...)`을 쓰게 했는데 그건 잊을 수 있는 규칙이었다.** 하나만
// 빠지면 optional 언랩이 런타임 분기가 되어 본문이 되살아나고 Windows 링크가 깨지는데, 그것을 잡아 줄 Windows
// CI가 없다(ubuntu·macOS만 돈다). 적대적 검증에서 나온 지적이라 **잊을 수 없는 구조**로 바꿨다 — 상수는
// 호출부가 실수할 여지가 없다.
const gate_ssh = hostGateReason(builtin.os.tag, .ssh);
const gate_install_cli = hostGateReason(builtin.os.tag, .install_cli);
const gate_control_socket = hostGateReason(builtin.os.tag, .control_socket);

/// `maru control --stdio` — 폰이 SSH 채널로 이 PC 의 컨트롤 플레인에 닿는 중계(S10c).
///
/// **stdout 은 오직 wire 다.** 그래서 사용법·오류는 전부 stderr 로 낸다 — 한 줄만 섞여도 폰의
/// ndjson 파서가 그 프레임을 잃는다([컨트롤 플레인 §4a](../docs/control-plane.md)).
fn runControl(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: *std.process.Args.Iterator,
    stderr: *std.Io.Writer,
) !void {
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    while (args.next()) |a| try rest.append(allocator, a);

    switch (maru.cli.control_relay.parseArgs(rest.items)) {
        .usage => |msg| {
            try stderr.print("{s}\n", .{msg});
            try stderr.flush();
            return error.UnknownCommand;
        },
        .stdio => try maru.cli.control_relay.relay(io, allocator, stderr),
    }
}

/// `maru agent-events --stdio --dir=<절대경로>` — RA4 의 impure 절반.
///
/// 순수 절반(`cli/agent_events.zig`)이 인자·프레임·커서를 갖고, 여기서는 디렉터리 열거·파일 읽기·
/// stdout 쓰기·시계만 한다. **stdout 은 오직 wire 다** — 진단은 전부 stderr 로 간다.
fn runAgentEvents(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: *std.process.Args.Iterator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const ae = maru.cli.agent_events;
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(allocator);
    while (args.next()) |a| try rest.append(allocator, a);

    const opts = switch (ae.parseArgs(rest.items)) {
        .help => {
            try stdout.writeAll("usage: maru agent-events --stdio --dir=<absolute path> [--heartbeat-ms=N]\n");
            try stdout.flush();
            return;
        },
        .usage_error => {
            try stderr.writeAll("maru agent-events: --stdio and an absolute --dir= are required\n");
            try stderr.flush();
            return error.UnknownCommand;
        },
        .stdio => |o| o,
    };

    // hello 를 **가장 먼저** 보낸다 — 소비자가 제한 서버(`ForceCommand`)를 이것으로 가른다.
    try stdout.print("{s}\n", .{ae.hello_line});
    try stdout.flush();

    var cursors: std.StringHashMapUnmanaged(ae.Cursor) = .empty;
    defer {
        var it = cursors.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        cursors.deinit(allocator);
    }

    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(allocator);

    var hb_seq: u64 = 0;
    var since_hb_ms: u64 = 0;
    const tick_ms: u64 = 200;

    // **스트리머가 없던 동안 자란 파일을 한 번 거둔다**(RA3). 소비자가 없으면 아무도 안 비우므로
    // 그 구간의 상한이 없다 — 계약 §4 가 «읽는 Term 이 없는 파일은 상한 없이 자랐다» 로 이미 겪었다.
    // **상한을 넘긴 것만** 거둔다: 이 프로세스는 사용자가 그 pane 을 보고 있는 동안에도 다시 뜨므로
    // (채널이 죽었다 살아난 경우) 전부 지우면 방금 생긴 이벤트를 버린다.
    if (std.Io.Dir.cwd().openDir(io, opts.dir, .{ .iterate = true })) |startup_dir| {
        var sd = startup_dir;
        defer sd.close(io);
        var sit = sd.iterate();
        while ((sit.next(io) catch null) orelse null) |entry| {
            if (entry.kind != .file) continue;
            if (ae.nonceFromFileName(entry.name) == null) continue;
            var f = sd.openFile(io, entry.name, .{}) catch continue;
            var sbuf: [64]u8 = undefined;
            var sr = f.reader(io, &sbuf);
            const sz = sr.getSize() catch {
                f.close(io);
                continue;
            };
            f.close(io);
            if (!ae.shouldDropAtStartup(sz)) continue;
            _ = sd.writeFile(io, .{ .sub_path = entry.name, .data = "", .flags = .{ .truncate = true } }) catch {};
        }
    } else |_| {}

    while (true) {
        var dir = std.Io.Dir.cwd().openDir(io, opts.dir, .{ .iterate = true }) catch {
            // 디렉터리가 아직 없을 수 있다 — 훅이 한 번도 안 돌았으면 그렇다. 조용히 기다린다
            // (그 사실은 소비자가 «이벤트가 없다» 로 이미 안다).
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(tick_ms), .awake) catch {};
            since_hb_ms += tick_ms;
            if (opts.heartbeat_ms != 0 and since_hb_ms >= opts.heartbeat_ms) {
                frame.clearRetainingCapacity();
                try ae.formatHeartbeat(&frame, allocator, hb_seq);
                hb_seq += 1;
                since_hb_ms = 0;
                try stdout.writeAll(frame.items);
                try stdout.flush();
            }
            continue;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while ((it.next(io) catch null) orelse null) |entry| {
            const nonce = ae.nonceFromFileName(entry.name) orelse continue;
            var file = dir.openFile(io, entry.name, .{}) catch continue;
            defer file.close(io);
            var rbuf: [4096]u8 = undefined;
            var reader = file.reader(io, &rbuf);
            const size = reader.getSize() catch continue;

            const gop = cursors.getOrPut(allocator, nonce) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = allocator.dupe(u8, nonce) catch {
                    _ = cursors.remove(nonce);
                    continue;
                };
                gop.value_ptr.* = .{};
            }
            const cur = ae.advance(gop.value_ptr.*, size);
            if (size <= cur.offset) {
                gop.value_ptr.* = cur;
                continue;
            }
            reader.seekTo(cur.offset) catch continue;
            // ⚠️ **한 회차에 읽는 양을 못 박되, 못 읽은 나머지는 다음 회차로 넘긴다.**
            //
            // 예전에는 `allocRemaining(.limited(1 MiB))` 로 «남은 전부» 를 요구했다. 그러면 안 읽은
            // 구간이 그 상한을 넘긴 파일은 **읽기 자체가 실패하고**, 실패는 `catch continue` 라
            // 그 파일이 **영영 소비되지 않는다** — 그리고 소비가 안 되니 절단도 안 걸려 계속 자란다.
            // 즉 상한이 «큰 파일을 지키는 장치» 가 아니라 «큰 파일을 영구히 버리는 장치» 였다
            // (실측: 1.25 MiB 로그에서 흘린 이벤트 0, stderr 도 비어 있어 조용했다).
            //
            // 지금은 고정 크기 한 조각만 읽고 그 안의 완성된 줄까지만 커서를 옮긴다. 폭주한 파일도
            // 회차를 거듭하며 따라잡고, 따라잡은 뒤에 절단이 걸린다.
            const chunk_buf = allocator.alloc(u8, ae.read_chunk_bytes) catch continue;
            defer allocator.free(chunk_buf);
            const got = reader.interface.readSliceShort(chunk_buf) catch continue;
            if (got == 0) {
                gop.value_ptr.* = cur;
                continue;
            }
            const chunk = chunk_buf[0..got];
            // 조각이 파일 끝에 닿았는가 — 닿지 않았다면 마지막 조각은 «아직 쓰는 중» 이 아니라
            // **우리가 자른 것**이므로, 개행 없는 꼬리를 버리지 않고 다음 회차로 넘긴다(아래 루프가
            // 개행까지만 세므로 두 경우가 같은 코드로 처리된다).

            var consumed: usize = 0;
            var lines = std.mem.splitScalar(u8, chunk, '\n');
            while (lines.next()) |line| {
                // 마지막 조각이 개행으로 안 끝나면 **아직 쓰는 중이거나 우리가 자른 것**이다 —
                // 어느 쪽이든 다음 회차에 그 자리부터 다시 본다.
                if (consumed + line.len >= chunk.len) break;
                consumed += line.len + 1;
                if (line.len == 0) continue;
                frame.clearRetainingCapacity();
                try ae.formatEvent(&frame, allocator, nonce, line);
                try stdout.writeAll(frame.items);
            }
            const next: ae.Cursor = .{ .offset = cur.offset + consumed, .seen_size = size };
            gop.value_ptr.* = next;

            // **다 읽었고 상한을 넘겼으면 비운다**(RA3 — 원격에서는 이 프로세스가 그 기계의 소비자다).
            // 실패는 조용히 지나간다: 못 비워도 이벤트는 계속 흐르고, 다음 회차에 다시 시도한다.
            if (ae.shouldTruncate(next, size)) {
                // `O_TRUNC` 로 열어 아무것도 안 쓴다 — 파일이 이미 있으므로 **권한은 그대로 남는다**
                // (훅이 `umask 077` 로 만든 0600 이다. 지우고 다시 만들면 그 값을 잃는다).
                if (dir.writeFile(io, .{ .sub_path = entry.name, .data = "", .flags = .{ .truncate = true } })) |_| {
                    // 비운 뒤 커서도 0 으로 되돌린다. `advance` 의 회전 감지가 다음 회차에 같은 일을
                    // 하겠지만, 여기서 함께 두어야 «비웠는데 커서가 남아» 새 이벤트를 건너뛰는 한
                    // 회차가 안 생긴다.
                    gop.value_ptr.* = .{ .offset = 0, .seen_size = 0 };
                } else |_| {}
            }
        }
        try stdout.flush();

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(tick_ms), .awake) catch {};
        since_hb_ms += tick_ms;
        if (opts.heartbeat_ms != 0 and since_hb_ms >= opts.heartbeat_ms) {
            frame.clearRetainingCapacity();
            try ae.formatHeartbeat(&frame, allocator, hb_seq);
            hb_seq += 1;
            since_hb_ms = 0;
            try stdout.writeAll(frame.items);
            try stdout.flush();
        }
    }
}

fn runSsh(io: std.Io, allocator: std.mem.Allocator, args: anytype, stderr: *std.Io.Writer) !void {
    // Windows 미지원(백로그 W9) — 이유는 `HostGatedFeature.ssh`. 여기서 접지 않으면 W2의 목표(Windows에서
    // maru가 빌드된다)가 성립하지 않는다. comptime 참이라 아래 POSIX 본문은 의미 분석되지 않는다(실측 확인).
    if (gate_ssh) |reason| {
        try stderr.print("{s}\n", .{reason});
        try stderr.flush();
        return error.UnknownCommand;
    }

    // `maru ssh [--terminfo-only] <ssh args...>`: 원격에 maru terminfo(xterm-maru)를 먼저 심고 평범한
    // ssh로 exec한다. 순수 로직(파싱·스크립트·argv)은 maru.cli.ssh가 갖고, 여기선 인자 수집과 actual
    // 프로세스 교체(execve)만 한다. "ssh" 뒤 인자를 execve까지 유효하도록 소유 복사해 모은다.
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (args.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    const parsed = maru.cli.ssh.parse(collected.items) catch |err| switch (err) {
        error.MissingDestination => {
            try stderr.writeAll("usage: maru ssh [--terminfo-only] <ssh args...>\n");
            try stderr.flush();
            return error.UnknownCommand;
        },
    };

    // control socket 경로(결정론적): HOME과 목적지로 maru ssh와 Maru 앱이 같은 경로를 도출한다(후속
    // "원격 인식" 단계가 같은 controlSocketPath를 재사용해 OSC 통지 없이 socket을 찾는다). 경로가 너무
    // 길거나 HOME/목적지가 없으면 빈 문자열 → 스크립트가 control socket 없이 폴백한다. getenv 같은 I/O는
    // 여기(main)서 하고, 경로 계산은 순수 함수(maru.cli.ssh.controlSocketPath)가 갖는다.
    const ctl: []const u8 = blk: {
        const home = hostHomeDir() orelse break :blk "";
        const dest = maru.cli.ssh.destination(parsed.ssh_args) orelse break :blk "";
        break :blk maru.cli.ssh.controlSocketPath(allocator, home, dest) catch |err| switch (err) {
            error.ControlPathTooLong => "", // 경로 한도 초과 → control socket 없이 폴백
            error.OutOfMemory => return err,
        };
    };
    defer if (ctl.len > 0) allocator.free(ctl);

    // 세션 수명 정책(keepalive·재접속)은 config `ssh.*`가 소유한다. **config를 못 읽어도 접속은 된다** —
    // 그때는 스키마 기본값과 같은 `SessionOpts` 기본값으로 간다(설정 파일이 없는 새 사용자와 같은 자리).
    // 여기서 읽는 이유는 이 값이 wrapper 스크립트의 인자이고, 스크립트는 execve 뒤에 config를 못 읽기 때문이다.
    var session_opts: maru.cli.ssh.SessionOpts = .{};
    if (maru.config.loader.loadDefault(io, allocator)) |loaded_config| {
        var loaded = loaded_config;
        defer loaded.deinit();
        session_opts = .{
            .server_alive_interval = loaded.config.ssh.server_alive_interval,
            .server_alive_count_max = loaded.config.ssh.server_alive_count_max,
            .reconnect = loaded.config.ssh.reconnect,
        };
    } else |_| {}

    // **pane 신원을 실어 보낸다**([계획](docs/plans/remote-agent-state.md) RA2). 값을 여기서 새로 짓지
    // 않고 **이 pane 의 셸 env 에 이미 있는 두 값**을 합친다 — 그 둘은 maru 가 자식 셸에 주입한 것이고
    // (`pty/macos.zig`), 로컬 훅이 로그 이름으로 쓰는 바로 그 값이다. 여기서 다시 계산하면 «훅이 쓰는
    // 이름 ≠ maru 가 읽는 이름» 이 조용히 성립한다(계약 §4 가 이미 겪은 사고다).
    //
    // **없으면 안 보낸다.** 사용자가 maru 밖 터미널에서 `maru ssh` 를 쳤을 수도 있다 — 그때는 귀속할
    // Term 이 애초에 없으므로 빈 값이 옳다(원격 훅은 nonce 가 비면 스스로 나간다).
    var nonce_buf: [maru.session.agent_hook_command.remote_pane_nonce_max]u8 = undefined;
    session_opts.remote_pane_nonce = blk: {
        const hc = maru.session.agent_hook_command;
        const inst = std.c.getenv(hc.instance_env) orelse break :blk null;
        const pane = std.c.getenv(hc.pane_env) orelse break :blk null;
        break :blk hc.formatRemotePaneNonce(&nonce_buf, std.mem.span(inst), std.mem.span(pane));
    };

    var scratch: maru.cli.ssh.ArgvScratch = .{};
    const argv = try maru.cli.ssh.buildArgv(allocator, parsed, ctl, session_opts, &scratch);
    defer allocator.free(argv);

    // execve용 null-terminated C argv(pty/macos.zig ArgvStorage와 같은 패턴). alloc은 미초기화
    // 메모리라, dupeZ가 도중에 실패(OOM)하면 아직 안 채운 슬롯은 쓰레기 slice다 — defer가 그걸 free하면
    // heap이 손상된다. built로 actual 채운 개수를 세어 채운 것만 free한다(ArgvStorage의 initialized 가드와 동치).
    const c_strings = try allocator.alloc([:0]u8, argv.len);
    defer allocator.free(c_strings);
    var built: usize = 0;
    defer for (c_strings[0..built]) |s| allocator.free(s);
    for (argv, 0..) |s, i| {
        c_strings[i] = try allocator.dupeZ(u8, s);
        built += 1;
    }

    const c_argv = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    defer allocator.free(c_argv);
    for (c_strings, 0..) |s, i| c_argv[i] = s.ptr;

    // 현재 환경을 상속해 `/bin/sh -c <script>`를 exec한다 — 성공하면 이 프로세스가 그 셸이 되고, 셸이
    // ssh를 자식으로 돌리며 끊기면 다시 붙는다(docs/ssh-integration.md §10). 돌아오면 실패다.
    // (SSH_AUTH_SOCK 등 환경은 그대로 흐른다. TERM은 스크립트가 `env`로 정한다.)
    _ = std.c.execve("/bin/sh", c_argv, @ptrCast(std.c.environ));
    try stderr.writeAll("maru ssh: failed to exec /bin/sh\n");
    try stderr.flush();
    return error.UnknownCommand;
}

/// `maru install-cli` 의 Windows 갈래(W10).
///
/// **POSIX 본문과 갈라 둔다.** 그쪽은 `std.c.symlink`·`std.c.mkdir` 를 부르는데 Windows 에서는 그
/// 심볼이 없다 — 위 게이트 상수들이 **comptime 으로 본문을 죽여** 링크를 지켜 온 그 구조 그대로,
/// 이 갈래도 comptime 분기 뒤에 산다.
///
/// **셋을 정했다**(계획 W10 의 선행 결정 3건). 근거는 전부 이 저장소의 단일 출처다.
///
/// | 결정 | 값 | 근거 |
/// |---|---|---|
/// | 위치 | `%LOCALAPPDATA%\maru\bin` | `user_paths` 모듈 doc — *"Windows 에서는 `%LOCALAPPDATA%\maru\` 아래로 모은다"* |
/// | shim | `maru.cmd` | symlink 는 개발자 모드·관리자 권한이 필요하다. `.cmd` 는 권한이 없고 `PATHEXT` 기본값에 든다 |
/// | PATH | **안내만** | 레지스트리를 쓰면 되돌리기와 실패 처리가 늘고, 사용자가 안 시킨 시스템 상태를 바꾼다 |
fn runInstallCliWindows(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    // **경로 값은 `os_env` 로 읽는다** — 비-ASCII 사용자명이 ACP 바이트로 오면 비교가 어긋난다.
    const local = maru.os_env.allocValue(allocator, "LOCALAPPDATA");
    defer if (local) |l| allocator.free(l);
    const home_env = maru.os_env.allocValue(allocator, "HOME");
    defer if (home_env) |h| allocator.free(h);
    const up_env = maru.os_env.allocValue(allocator, "USERPROFILE");
    defer if (up_env) |u| allocator.free(u);
    const home = maru.user_paths.homeDirFor(.windows, home_env, up_env);

    const bindir = (try maru.cli.install.binDirFor(allocator, .windows, home, local)) orelse {
        try stderr.writeAll("maru install-cli: cannot determine the install location: neither %LOCALAPPDATA% nor a home directory\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer allocator.free(bindir);
    const shim = (try maru.cli.install.shimPathFor(allocator, .windows, home, local)).?;
    defer allocator.free(shim);

    std.Io.Dir.cwd().createDirPath(io, bindir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try stderr.print("maru install-cli: cannot create {s}\n", .{bindir});
            try stderr.flush();
            return error.UnknownCommand;
        },
    };

    const body = try maru.cli.install.cmdShimContents(allocator, exe_path);
    defer allocator.free(body);
    // **원자적으로 바꾼다** — 반쯤 쓰인 `.cmd` 는 셸이 그대로 실행한다. 재실행 안전(idempotent)이다.
    var af = std.Io.Dir.cwd().createFileAtomic(io, shim, .{ .replace = true, .make_path = true }) catch {
        try stderr.print("maru install-cli: cannot write {s}\n", .{shim});
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer af.deinit(io);
    var wbuf: [512]u8 = undefined;
    var fw = af.file.writer(io, &wbuf);
    fw.interface.writeAll(body) catch return error.UnknownCommand;
    fw.interface.flush() catch return error.UnknownCommand;
    af.replace(io) catch {
        try stderr.print("maru install-cli: cannot replace {s}\n", .{shim});
        try stderr.flush();
        return error.UnknownCommand;
    };

    // **보여 줄 때는 Windows 모양으로 되돌린다.** 안쪽은 `/` 로 정규화된 형태이고(입구 정규화,
    // 계약 §5), 사용자가 그대로 붙여 넣을 `setx` 줄에 두 구분자가 섞여 있으면 읽기 나쁘다.
    const shim_native = try maru.path_shape.toNativeSeparatorsFor(.windows, allocator, shim);
    defer allocator.free(shim_native);
    const bindir_native = try maru.path_shape.toNativeSeparatorsFor(.windows, allocator, bindir);
    defer allocator.free(bindir_native);
    try stdout.print("maru CLI installed: {s} -> {s}\n", .{ shim_native, exe_path });

    if (maru.os_env.allocValue(allocator, "PATH")) |path_value| {
        defer allocator.free(path_value);
        // **Windows 규칙으로 본다** — `;` 구분, 대소문자 무시, `/`·`\` 동일시. POSIX 규칙으로 보면
        // `C:` 에서 두 동강 나 이미 PATH 에 있어도 늘 안내가 뜬다.
        if (!maru.cli.install.pathContainsDirFor(.windows, path_value, bindir)) {
            try stdout.print(
                "\nnote: {s} is not on PATH. Add it for this user with:\n  setx PATH \"%PATH%;{s}\"\nThen open a new terminal.\n",
                .{ bindir_native, bindir_native },
            );
        }
    }
    try stdout.flush();
}

fn runInstallCli(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // **Windows 는 갈라진다**(W10). 이 분기가 `comptime` 인 이유는 아래 POSIX 본문이 `std.c.symlink`·
    // `std.c.mkdir` 를 부르기 때문이다 — 게이트 상수들이 지켜 오던 그 성질을 그대로 쓴다: 참인
    // 갈래 뒤는 **의미 분석되지 않아** Windows 에서 그 심볼을 안 찾는다.
    if (comptime builtin.os.tag == .windows) {
        return runInstallCliWindows(io, allocator, stdout, stderr);
    }

    // `maru install-cli`: 현재 maru 바이너리를 `~/.local/bin/maru`에 symlink해 셸 PATH에서 쓸 수 있게
    // 한다(VS Code `code` 설치식). 순수 경로/PATH 로직은 maru.cli.install, 여기선 자기 경로 resolve와
    // actual mkdir/symlink(std.c)만 한다. sudo가 필요 없는 user-level 경로라 권한 상승이 없다.
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    const home = hostHomeDir() orelse {
        try stderr.writeAll("maru install-cli: cannot determine the install location: no home directory ($HOME)\n");
        try stderr.flush();
        return error.UnknownCommand;
    };

    const bindir = try maru.cli.install.binDir(allocator, home);
    defer allocator.free(bindir);
    const link = try maru.cli.install.linkPath(allocator, home);
    defer allocator.free(link);

    // mkdir -p ~/.local/bin (단계별, 이미 있으면 무시 — std.c.mkdir는 EEXIST를 에러로 주지만 무시한다).
    const local = try std.fmt.allocPrintSentinel(allocator, "{s}/.local", .{home}, 0);
    defer allocator.free(local);
    _ = std.c.mkdir(local.ptr, 0o755);
    _ = std.c.mkdir(bindir.ptr, 0o755);

    // 기존 링크/파일을 지우고(없으면 무시) 새로 건다 — 재실행 안전(idempotent).
    _ = std.c.unlink(link.ptr);
    if (std.c.symlink(exe_path.ptr, link.ptr) != 0) {
        try stderr.print("maru install-cli: symlink failed: {s}\n", .{link});
        try stderr.flush();
        return error.UnknownCommand;
    }

    try stdout.print("maru CLI installed: {s} -> {s}\n", .{ link, exe_path });

    // bin 디렉터리가 PATH에 없으면 추가 방법을 안내한다.
    // `PATH` 도 경로 값이라 `os_env` 로 읽는다 — 비-ASCII 사용자명이 든 항목이 ACP 바이트로 오면
    // `pathContainsDir` 의 비교가 어긋나 "PATH 에 없다" 는 안내가 잘못 뜬다.
    if (maru.os_env.allocValue(allocator, "PATH")) |path_value| {
        defer allocator.free(path_value);
        if (!maru.cli.install.pathContainsDir(path_value, bindir)) {
            try stdout.print(
                "\nnote: {s} is not on PATH. Add the following to your shell config (~/.zshrc etc.):\n  export PATH=\"{s}:$PATH\"\n",
                .{ bindir, bindir },
            );
        }
    }
    try stdout.flush();
}

// `/bin/sh -c <cmd>`를 돌려 기다린다(POSIX). std.c에 노출이 없어 직접 선언한다(pty/macos.zig와 같은 결).
extern "c" fn system(command: [*:0]const u8) c_int;

/// `system()`이 POSIX 셸 문법을 이해하는가. **Windows에서는 아니다.**
///
/// msvcrt의 `system()`은 `%COMSPEC%`(= cmd.exe)로 간다 — 프로세스를 **어느 셸에서 띄웠든** 그렇다.
/// 실측: git-bash에서 `maru terminfo --refresh`를 돌려도 cmd.exe가 `d='...'`를 명령 이름으로 읽어
/// `'d' is not recognized`로 죽는다. 그래서 "git-bash에서 실행하세요"는 **틀린 안내**였다.
///
/// 단일 외부 명령(예: `rm -rf '<경로>'`)은 cmd.exe도 실행할 수 있어, git이 설치돼 `rm.exe`가 PATH에
/// 있으면 `--clear`는 우연히 동작한다. 반면 `VAR=값 명령` 접두나 `d=...; ...` 대입은 POSIX 문법이라
/// 무엇을 깔아도 안 된다. 계약 §5.3 "이 슬라이스가 닫지 않은 것" 참조.
fn posixShellCommandsWork() bool {
    return @import("builtin").os.tag != .windows;
}

fn runTerminfo(allocator: std.mem.Allocator, args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // `maru terminfo [--status|--refresh|--clear|--path]`: maru 자체 terminfo(xterm-maru)의 로컬 캐시를
    // 관리한다. 순수 인자 파싱은 maru.cli.terminfo, 캐시 경로·버전·셸 명령은 maru.terminfo_cache(pty 자동
    // 컴파일과 공유), 여기선 인자 수집과 셸 실행·출력만 한다. "terminfo" 뒤 인자를 모은다.
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (args.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    const action = maru.cli.terminfo.parse(collected.items) catch {
        try stderr.writeAll("usage: maru terminfo [--status|--refresh|--clear|--path]\n");
        try stderr.flush();
        return error.UnknownCommand;
    };

    const home_raw = hostHomeDir() orelse {
        try stderr.writeAll("maru terminfo: cannot determine the cache location: no home directory ($HOME" ++
            (if (@import("builtin").os.tag == .windows) "·%USERPROFILE%" else "") ++ ")\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    // 셸 명령과 같은 XDG 규칙으로 캐시 경로를 보여준다(둘이 같은 위치로 resolve).
    //
    // **입구 정규화**(docs/windows-platform.md §5): 환경변수에서 온 경로는 native 구분자다. 중립 레이어는
    // 이을 때 항상 `/`를 쓰므로(layering §4.1) 그대로 넘기면 결과가 섞인다 — 실측으로 확인한 모양이
    // `C:\Users\me/.cache/maru/terminfo`였다. POSIX에서는 무동작이라 macOS 동작이 바뀌지 않는다.
    // base 판정은 `user_paths.cacheBaseFor`가 소유한다 — `$XDG_CACHE_HOME`이 모든 OS에서 최우선이고,
    // Windows에서는 그 다음이 `%LOCALAPPDATA%`다(계약 §5.3). 여기서는 환경변수 읽기와 입구 정규화만 한다.
    // `getenv` 가 아니라 `os_env` 로 읽는다 — Windows 의 ANSI 환경은 비-ASCII 사용자명에서 ACP 바이트를
    // 준다(그 doc 참조). 여기서 그것을 정규화하면 cp949 trail 바이트가 `0x5C` 일 때 글자 한가운데를 바꿔
    // **다른 캐시 디렉터리**를 만든다.
    const xdg_raw = maru.os_env.allocValue(allocator, "XDG_CACHE_HOME");
    defer if (xdg_raw) |x| allocator.free(x);
    const local_raw = maru.os_env.allocValue(allocator, "LOCALAPPDATA");
    defer if (local_raw) |l| allocator.free(l);
    const base_raw = maru.user_paths.cacheBaseFor(@import("builtin").os.tag, xdg_raw, local_raw);
    const xdg: ?[]const u8 = if (base_raw) |b| try maru.path_shape.normalizeSeparators(allocator, b) else null;
    defer if (xdg) |x| allocator.free(x);
    const home = try maru.path_shape.normalizeSeparators(allocator, home_raw);
    defer allocator.free(home);

    const dir = try maru.terminfo_cache.cacheDirZ(allocator, xdg, home);
    defer allocator.free(dir);

    switch (action) {
        // 스크립트에서 캐시 경로만 필요할 때(예: 지우기 자동화). 경로만 한 줄 출력한다.
        .path => try stdout.print("{s}\n", .{dir}),
        // 캐시가 컴파일돼 xterm-maru가 해석되는지 보고한다(아무것도 바꾸지 않는 안전 기본).
        .status => {
            try stdout.print("maru terminfo cache: {s}\n", .{dir});
            try stdout.flush(); // system()이 fd로 직접 쓰므로 버퍼를 먼저 비운다.
            // **Windows에서는 상태를 알 수 없다 — 모른다고 말한다.** 프로브가
            // `TERMINFO=<dir> infocmp xterm-maru`인데 그 `VAR=값 명령` 접두는 POSIX 문법이고,
            // `system()`은 여기서 `%COMSPEC%`(cmd.exe)로 간다(실측: `'TERMINFO' is not recognized`).
            // 즉 프로브가 **항상 실패**해서, 예전 코드는 캐시가 actual로 컴파일돼 있어도 늘
            // "아직 컴파일 안 됨"이라고 단언했다 — 모르는 것을 아는 것처럼 말하는 쪽이 더 나쁘다.
            if (!posixShellCommandsWork()) {
                try stdout.writeAll("status: unknown — checking requires a POSIX shell, but this host's `system()` goes to cmd.exe\n");
                try stdout.flush();
                return;
            }
            const cmd = try maru.terminfo_cache.statusCommand(allocator, dir);
            defer allocator.free(cmd);
            if (system(cmd.ptr) == 0) {
                try stdout.writeAll("status: xterm-maru compiled (config term = \"xterm-maru\"uses this cache as TERMINFO)\n");
            } else {
                try stdout.writeAll("status: not compiled yet — running maru once compiles it, or compile now with `maru terminfo --refresh`\n");
            }
        },
        // 업데이트로 terminfo 캡이 바뀐 뒤 등, 캐시를 강제로 비우고 다시 컴파일한다(보통은 자동 stale 감지로
        // 불필요하지만 강제·복구용). tic 경고/오류는 사용자에게 그대로 보인다.
        .refresh => {
            const cmd = try maru.terminfo_cache.refreshCommand(allocator, dir, maru.terminfo_cache.version());
            defer allocator.free(cmd);
            try stdout.print("maru terminfo cache recompiled: {s}\n", .{dir});
            try stdout.flush();
            if (system(cmd.ptr) == 0) {
                try stdout.writeAll("done: xterm-maru recompiled\n");
            } else {
                // Windows에서는 원인이 하나 더 있다. `system()`은 여기서 `/bin/sh`가 아니라 **cmd.exe**로
                // 가는데(msvcrt), 재컴파일 명령은 `rm -rf`·`mkdir -p`·`printf`를 쓰는 POSIX 스크립트다.
                // 실측(PowerShell·cmd): 그 넷도 `tic`도 PATH에 없다 — 둘 다 git-bash의 `/usr/bin`에만 있다.
                // 그래서 tic만 가리키면 사용자가 tic을 깔아도 여전히 실패한다. 계약 §8 "홈·캐시 위치" 참조.
                try stderr.writeAll(if (!posixShellCommandsWork())
                    "maru terminfo: recompiling is not supported on this host — the recompile command uses POSIX shell syntax (`d=...; rm -rf ...`) but\n" ++
                        "  `system()` goes to cmd.exe. **This holds even when maru is launched from git-bash** (%COMSPEC% decides, not the shell).\n" ++
                        "  even without recompiling, the terminal falls back to xterm-256color and works.\n"
                else
                    "maru terminfo: recompile failed — check that tic (ncurses) is installed (the shell falls back to xterm-256color)\n");
                try stderr.flush();
                return error.UnknownCommand;
            }
        },
        // 캐시 디렉터리를 통째로 지운다(다음 maru 실행이 자동 재컴파일).
        .clear => {
            const cmd = try maru.terminfo_cache.clearCommand(allocator, dir);
            defer allocator.free(cmd);
            // **반환값을 봐야 한다.** 예전에는 버렸는데, Windows에서 `system()`이 cmd.exe로 가 `rm`이 없어
            // 실패하는데도 "삭제: <경로>"를 exit 0으로 찍었다(실측) — 지우지 않고 지웠다고 말하는 셈이다.
            // POSIX에서 `rm -rf`는 대상이 없어도 0이라 이 검사가 정상 경로를 막지 않는다.
            if (system(cmd.ptr) != 0) {
                try stdout.flush();
                try stderr.print("maru terminfo: failed to remove the cache — {s}\n", .{dir});
                if (!posixShellCommandsWork())
                    // 이 명령만은 단일 외부 명령(`rm -rf '<경로>'`)이라 cmd.exe도 실행할 수 있다 —
                    // `rm.exe`가 PATH에 있으면(git 설치본) 된다. 그래서 안내가 "셸을 바꾸라"가 아니라
                    // "PATH에 rm이 있느냐"다(재컴파일 쪽과 원인이 다르다).
                    try stderr.writeAll("  `rm` is not on PATH (it lives under a git installation's usr) — you can delete that folder yourself\n");
                try stderr.flush();
                return error.UnknownCommand;
            }
            try stdout.print("maru terminfo cache removed: {s}\n", .{dir});
        },
    }
    try stdout.flush();
}

/// `maru trace anonymize <in> [out]`: 캡처한 trace(`MARU_TRACE`)의 PII(경로·IP·user@host·유저명)를 일반화해
/// fixture로 커밋 가능하게 만든다. 순수 파싱은 maru.cli.trace, 익명화는 maru.observability.trace, 여기선 파일 I/O·
/// env(HOME/USER)·경고만 한다. 익명화 후에도 남은 secret 할당(TOKEN=…)은 경고한다(가드가 커밋 시 차단).
fn runTrace(io: std.Io, allocator: std.mem.Allocator, args: anytype, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (args.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    const cmd = maru.cli.trace.parse(collected.items) catch {
        try stderr.writeAll("usage: maru trace anonymize <input.trace> [output.trace]\n");
        try stderr.flush();
        return error.UnknownCommand;
    };

    switch (cmd) {
        .anonymize => |an| {
            const input = std.Io.Dir.cwd().readFileAlloc(io, an.input, allocator, .limited(64 * 1024 * 1024)) catch |e| {
                try stderr.print("maru trace anonymize: '{s}' read failed ({s})\n", .{ an.input, @errorName(e) });
                try stderr.flush();
                return error.UnknownCommand;
            };
            defer allocator.free(input);

            // 여기의 `home`은 **매칭 키**다(트레이스에서 홈 경로를 지운다) — 그래서 정규화하지 않는다
            // (계약 §5, W3). 폴백을 넣되 그 값은 제한적이다(실측): 익명화기가 `…/Users/<name>/` 모양을
            // **자체 규칙으로 이미** 일반화하므로 `C:\Users\me`는 `home`이 null이어도 지워진다. `home`이
            // 값을 하는 것은 **관례 밖 홈**뿐이다 — `D:\myhome`은 `home` 없이는 그대로 남고, 있으면
            // `D:/user`로 바뀐다. Windows 폴백은 그 자리를 닫는다.
            const opts: maru.redact.AnonymizeOptions = .{
                .home = hostHomeDir(),
                .username = if (std.c.getenv("USER")) |u| std.mem.span(u) else null,
            };
            const anon = maru.observability.trace.anonymizeTrace(allocator, input, opts) catch |e| {
                try stderr.print("maru trace anonymize: conversion failed ({s}) — is it a valid maru.trace.v1?\n", .{@errorName(e)});
                try stderr.flush();
                return error.UnknownCommand;
            };
            defer allocator.free(anon);

            if (an.output) |out_path| {
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = anon, .flags = .{ .truncate = true } });
                try stdout.print("anonymized -> {s} ({d} bytes)\n", .{ out_path, anon.len });
            } else {
                try stdout.writeAll(anon);
            }

            // 익명화는 secret(TOKEN=…)을 안 지운다 — 남아 있으면 경고(커밋 시 guardFixture가 차단).
            if (maru.observability.trace.traceHasSensitiveContent(allocator, anon) catch false) {
                try stderr.writeAll("warning: sensitive assignments (TOKEN/SECRET/… = value) remain after anonymizing — remove them by hand before committing\n");
                try stderr.flush();
            }
        },
    }
    try stdout.flush();
}

/// `maru sessions ...` / `maru session ...` 두 컨트롤 플레인 read-only 명령의 얇은 접착(Track C 1d·A2a). 순수
/// 파싱·요청 조립·응답 포맷·소켓 발견 정책은 `maru.cli.sessions`가 갖고, 여긴 인자 수집·getenv/readdir/소켓 syscall·
/// stdout/stderr I/O만 한다(ssh/terminfo와 같은 결 — §11 "소켓 syscall L4·CLI는 src/cli·main 얇게"). `--help`는
/// 구현된 명령만 담은 help를 낸다(§11 CLI help gate). **A2a**: 요청은 이제 actual로 컨트롤 소켓에 connect해 왕복한다 —
/// 결정론 경로(`<cache>/maru/control`)에서 단일 인스턴스 소켓을 찾아(§4.2) `buildRequestBytes` 전송 → hello skip →
/// 응답 프레임(1a `Framer`) 수신 → `renderResponse`로 사람이 읽게 낸다. 살아있는 인스턴스가 없거나 connect가 실패하면
/// crash/트레이스 없이 graceful하게 안내하고 종료한다. 서버가 소켓을 actual로 띄우는 배선(accept-loop 스레드·메인
/// marshal(§5)·실 collector·capability auth(1e))은 **A2b/후속**이라, 지금은 보통 "인스턴스 없음"으로 접힌다.
const SessionCli = enum { sessions, session };

const PersistentReadCli = enum { host, runtime };

fn runPersistentReadCli(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    which: PersistentReadCli,
) !void {
    const runtime_cli = maru.cli.runtime;
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |item| allocator.free(item);
        collected.deinit(allocator);
    }
    while (args.next()) |arg| try collected.append(allocator, try allocator.dupe(u8, arg));
    const parsed = (switch (which) {
        .host => runtime_cli.parseHost(collected.items),
        .runtime => runtime_cli.parseRuntime(collected.items),
    }) catch {
        try stderr.writeAll(switch (which) {
            .host => runtime_cli.host_help,
            .runtime => runtime_cli.runtime_help,
        });
        return persistentCliExit(stdout, stderr, .usage);
    };
    switch (parsed) {
        .help => {
            try stdout.writeAll(switch (which) {
                .host => runtime_cli.host_help,
                .runtime => runtime_cli.runtime_help,
            });
            try stdout.flush();
            return;
        },
        .request => |request| {
            if (builtin.os.tag != .macos) {
                try stderr.writeAll("maru: persistent session host is unsupported on this platform\n");
                return persistentCliExit(stdout, stderr, .unsupported);
            }
            return session_host_admin_cli.runRequest(io, allocator, request, stdout, stderr);
        },
    }
}

fn runIncidentsCli(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const incidents_cli = maru.cli.incidents;
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |item| allocator.free(item);
        collected.deinit(allocator);
    }
    while (args.next()) |arg| try collected.append(allocator, try allocator.dupe(u8, arg));

    const parsed = incidents_cli.parse(collected.items) catch {
        try stderr.writeAll(incidents_cli.help);
        return persistentCliExit(stdout, stderr, .usage);
    };
    switch (parsed) {
        .help => {
            try stdout.writeAll(incidents_cli.help);
            try stdout.flush();
            return;
        },
        .list => |request| {
            // artifact 는 HOME 아래 고정 경로에 있다. 살아 있는 인스턴스를 찾지 않는 것이 이 명령의 요점이라
            // 컨트롤 소켓도 host registry 도 건드리지 않는다.
            const home = maru.os_env.allocValue(allocator, "HOME") orelse {
                try stderr.writeAll("maru: HOME is not set\n");
                return persistentCliExit(stdout, stderr, .usage);
            };
            defer allocator.free(home);
            const xdg_cache_home = maru.os_env.allocValue(allocator, "XDG_CACHE_HOME");
            defer if (xdg_cache_home) |value| allocator.free(value);
            const localappdata = maru.os_env.allocValue(allocator, "LOCALAPPDATA");
            defer if (localappdata) |value| allocator.free(value);
            const cache_base = maru.user_paths.cacheBaseFor(builtin.os.tag, xdg_cache_home, localappdata);
            return maru.cli.incidents_run.run(io, allocator, request, home, cache_base, stdout, stderr);
        },
    }
}

fn persistentCliExit(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    code: maru.cli.runtime.ExitCode,
) noreturn {
    stderr.flush() catch {};
    stdout.flush() catch {};
    std.process.exit(@intFromEnum(code));
}

fn runAttachCli(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |item| allocator.free(item);
        collected.deinit(allocator);
    }
    while (args.next()) |arg| try collected.append(allocator, try allocator.dupe(u8, arg));

    const command = maru.cli.attach.parse(collected.items) catch |err| {
        try stderr.print("maru attach: {s}\n\n", .{@errorName(err)});
        try stderr.writeAll(maru.cli.attach.help);
        return attachCliExit(stdout, stderr, .usage);
    };
    switch (command) {
        .help => {
            try stdout.writeAll(maru.cli.attach.help);
            try stdout.flush();
        },
        .attach => |request| {
            if (builtin.os.tag != .macos) {
                try stderr.writeAll("maru: persistent session attach is unsupported on this platform\n");
                return attachCliExit(stdout, stderr, .unsupported);
            }
            const code = try session_host_attach_cli.runRequest(io, allocator, request, stderr);
            return attachCliExit(stdout, stderr, code);
        },
    }
}

fn attachCliExit(
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    code: maru.cli.attach.ExitCode,
) noreturn {
    stderr.flush() catch {};
    stdout.flush() catch {};
    std.process.exit(@intFromEnum(code));
}

fn runSessionCli(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    which: SessionCli,
) !void {
    // 서브커맨드 뒤 인자를 소유 복사해 모은다(ssh/terminfo와 같은 패턴).
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (args.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    const parsed = (switch (which) {
        .sessions => maru.cli.sessions.parseSessions(collected.items),
        .session => maru.cli.sessions.parseSession(collected.items),
    }) catch |err| {
        try writeSessionCliUsage(stderr, which, err);
        return error.UnknownCommand;
    };

    switch (parsed) {
        .help => {
            try stdout.writeAll(switch (which) {
                .sessions => maru.cli.sessions.sessions_help,
                .session => maru.cli.sessions.session_help,
            });
            try stdout.flush();
        },
        .request => |req| try runSessionRequest(io, allocator, req, stdout, stderr),
    }
}

/// `sessions list`/`session get` 요청을 actual 컨트롤 소켓에 왕복한다(A2a). 소켓 흐름은 `cli.control_client`,
/// 요청 조립·응답 렌더만 `cli.sessions`. 살아있는 인스턴스가 없거나 connect 실패면 crash 없이 graceful 종료(exit 1).
fn runSessionRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    req: maru.cli.sessions.Request,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    // 응답 렌더 모양(list=배열, get=단건)은 요청 종류로 정해진다(1d ResponseKind).
    const kind: maru.cli.sessions.ResponseKind = switch (req) {
        .list => .list,
        .get => .get,
    };
    const request_bytes = try maru.cli.sessions.buildRequestBytes(allocator, req, .{ .number = 1 });
    defer allocator.free(request_bytes);
    const resp = try maru.cli.control_client.fetchResponse(io, allocator, request_bytes, stderr);
    defer allocator.free(resp);
    try maru.cli.sessions.renderResponse(allocator, resp, kind, stdout);
    try stdout.flush();
}

/// PTY 백엔드가 없는 호스트에서 `demo`·`app-pty-*`를 부른 경우. 안내를 내고 **기존 sentinel**
/// (`error.UnknownCommand` = "usage 에러를 이미 안내했다")로 돌아간다 — `main`이 그것을 잡아 트레이스 없이
/// 종료한다. 안 그러면 `UnsupportedPtySession`의 `error.UnsupportedPlatform`이 main 밖으로 흘러 6프레임
/// 스택 트레이스가 덤프되고 사용자에겐 crash로 보인다(실측 19줄).
///
/// **잡지 않고 미리 판정한다.** 처음엔 `main`에서 `error.UnsupportedPlatform`을 잡으려 했는데, 그 오류는
/// PTY 스텁만 내므로 **macOS에서는 `dispatch`의 추론 error set에 아예 없다** — 없는 오류를 switch하면
/// 컴파일 오류다(macOS CI가 잡았다: *"'error.UnsupportedPlatform' not a member of destination error set"*).
/// 판정을 앞으로 옮기면 새 오류가 집합에 들어가지 않아 두 호스트에서 같은 코드가 선다.
///
/// 판정은 `printSmoke`의 미리 안내와 **같은 사실**(`pty.backend_available`)을 본다 — 갈리면 "안내는 안 뜨는데
/// 실행하면 실패"가 된다. 그 상수와 actual spawn 실패의 일치는 `pty/session.zig` 테스트가 지킨다.
/// 백엔드가 있는데 spawn이 실패하는 경우는 여기 안 걸리고 그대로 오류로 남는다(진짜 오류는 트레이스가 맞다).
fn ptyBackendMissing(stderr: *std.Io.Writer) error{UnknownCommand} {
    stderr.writeAll(
        "this command needs a PTY backend, which this platform does not have yet " ++
            "(docs/plans/windows-platform.md W4 — ConPTY).\n" ++
            "runs without a PTY: maru app-smoke, maru app-loop-smoke, maru terminfo\n",
    ) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

fn writeSessionCliUsage(stderr: *std.Io.Writer, which: SessionCli, err: maru.cli.sessions.ParseError) !void {
    const reason = switch (err) {
        error.MissingSubcommand => "a subcommand is required",
        error.UnknownSubcommand => "unknown subcommand",
        error.MissingSurfaceId => "a surface id is required",
        error.InvalidSurfaceId => "the surface id must be a non-negative integer",
        error.MissingWindowValue => "--window needs a value",
        error.InvalidWindowValue => "the --window value must be a non-negative integer",
        error.UnknownOption => "unknown option",
        error.UnexpectedArgument => "too many arguments",
    };
    try stderr.print("maru {s}: {s}\n\n", .{ @tagName(which), reason });
    try stderr.writeAll(switch (which) {
        .sessions => maru.cli.sessions.sessions_help,
        .session => maru.cli.sessions.session_help,
    });
    try stderr.flush();
}

fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage:
        \\  maru
        \\  maru demo
        \\  maru app-smoke
        \\  maru app-loop-smoke
        \\  maru app-pty-loop-smoke
        \\  maru app-pty-interactive-loop-smoke
        \\  maru app-pty-smoke
        \\  maru win32-window-smoke
        \\  maru d3d11-present-smoke
        \\  maru d3d11-cells-smoke
        \\  maru dwrite-text-smoke
        \\  maru win32-frame-smoke
        \\  maru win32-terminal-smoke
        \\  maru win32-clipboard-smoke [<expected> | --paste-encode]
        \\  maru ssh [--terminfo-only] <ssh args...>
        \\  maru install-cli
        \\  maru terminfo [--status|--refresh|--clear|--path]
        \\  maru sessions list [--window <id>]
        \\  maru session get <id>
        \\  maru host status [--json]
        \\  maru runtime list [--json]
        \\  maru runtime get <32-lower-hex-runtime-id> [--json]
        \\  maru runtime end <32-lower-hex-runtime-id> [--yes]
        \\  maru attach [--read-only | --take-over] <32-lower-hex-runtime-id>
        \\  maru trace anonymize <input.trace> [output.trace]
        \\
        \\commands:
        \\  demo       run the headless PTY -> SurfaceRuntime -> snapshot demo
        \\  app-smoke  run the app host -> RuntimeEventPump -> RenderFrame smoke
        \\  app-loop-smoke run the repeated app frame-loop smoke
        \\  app-pty-loop-smoke run the live PTY -> repeated app frame-loop smoke
        \\  app-pty-interactive-loop-smoke run the interactive shell -> repeated app frame-loop smoke
        \\  app-pty-smoke run the live PTY -> app host -> RenderFrame smoke
        \\  win32-window-smoke open a real Win32 window and report the neutral events it delivers (Windows only; needs an interactive desktop)
        \\  d3d11-present-smoke paint that window with D3D11 + DXGI and report the present path (Windows only; needs a D3D11 device)
        \\  d3d11-cells-smoke draw a cell grid with synthesized glyphs through the D3D11 cell pipeline (Windows only; needs a D3D11 device)
        \\  dwrite-text-smoke render real text with DirectWrite glyphs plus synthesized box drawing (Windows only; needs a D3D11 device)
        \\  win32-frame-smoke run a live PTY through the Windows shaper and DirectWrite rasterizer into a neutral RenderFrame (Windows only; no window)
        \\  win32-terminal-smoke draw a live shell session on screen with D3D11 + DirectWrite (Windows only; needs an interactive desktop)
        \\  win32-clipboard-smoke round-trip text through the OS clipboard (Windows only; no window needed).
        \\                        with <expected>: read what another app put there and compare.
        \\                        with --paste-encode: run the current clipboard through the paste rules.
        \\  ssh        install maru terminfo on the remote, then exec ssh (opt-in; your normal ssh is untouched)
        \\  install-cli  symlink the maru binary into ~/.local/bin so `maru` works on your PATH
        \\  terminfo   manage the local xterm-maru terminfo cache (--status default, --refresh, --clear, --path)
        \\  sessions   list running Maru sessions (surfaces) as read-only metadata (`sessions --help`)
        \\  session    read-only metadata for a single surface (`session get <id>`, `session --help`)
        \\  host       inspect the existing persistent session host without starting one (`host --help`)
        \\  runtime    inspect or explicitly end persistent runtimes without starting a host (`runtime --help`)
        \\  attach     attach this terminal to an existing persistent runtime (`attach --help`)
        \\  browser    control a web surface (navigate/get-url/exec/get-cookies; asks for confirmation) (`browser --help`)
        \\  trace      anonymize a captured MARU_TRACE (paths/IPs/user@host/username) for fixture promotion
        \\
    );
    try writer.flush();
}

test "development CLI imports maru module" {
    try std.testing.expectEqual(@as(u16, 80), maru.terminal.Size.default.cols);
}

// **테스트가 이 파일까지 닿게 한다.** Zig는 선언을 게으르게 분석한다. 테스트 빌드에는 `main()`이 없으니
// 위의 `win32_window` import를 아무도 참조하지 않고, 그러면 그 파일 안의 테스트가 **수집조차 되지 않는다**.
// 실측으로 겪었다: 2,614개가 통과하는 동안 `win32_window` 테스트는 0개 돌았다. `check-targets`가 `main.zig`를
// 놓쳤던 것과 같은 부류이며, 여기 한 줄이 그 구멍을 막는다.
test {
    _ = win32_window;
    _ = d3d11_present;
    _ = d3d11_cells;
    _ = dwrite_font;
    _ = win32_text;
    _ = win32_terminal;
    _ = win32_keys;
    _ = win32_clipboard;
    _ = win32_mouse;
}

// W2가 지키려는 성질: **Windows에서 maru가 빌드·실행된다.** 그러려면 POSIX 전제 명령 셋(ssh·install-cli·
// 컨트롤 소켓)이 거기서 접혀야 한다 — 안 접으면 `environ`·`symlink`·`socket`이 undefined symbol이라 링크가 깨진다.
//
// 술어가 OS를 **인자로** 받으므로 이 테스트는 Windows 러너 없이도 두 갈래를 모두 실행한다. 컴파일 타임 분기로
// 두면 이 단언들이 비-Windows CI에서 공허참이 되는데, 그 함정은 W1.5 코드 리뷰에서 이미 한 번 밟았다.
test "host gate: POSIX 전제 명령은 Windows에서만 접히고, 이유가 사용자에게 보인다" {
    // **아직 막힌 것**. `install_cli` 는 W10 이 열었다(§2m.62).
    const gated = [_]HostGatedFeature{ .ssh, .control_socket };
    const features = [_]HostGatedFeature{ .ssh, .install_cli, .control_socket };

    // Windows: 막힌 것은 이유 문구가 있다(빈 문자열이면 사용자가 무슨 일인지 못 안다).
    for (gated) |f| {
        const reason = hostGateReason(.windows, f) orelse return error.TestUnexpectedResult;
        try std.testing.expect(reason.len > 0);
    }

    // **열린 것은 Windows 에서도 null 이다** — 게이트를 풀고 문구만 남기면 명령이 여전히 죽는다.
    try std.testing.expect(hostGateReason(.windows, .install_cli) == null);

    // 다른 호스트: 셋 다 열려 있다. macOS/Linux 동작이 이 슬라이스로 바뀌지 않는다는 증거다.
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| {
        for (features) |f| try std.testing.expect(hostGateReason(os, f) == null);
    }

    // 백로그 슬라이스 번호를 문구에 담아 둔다 — "안 된다"만 말하고 어디서 하는지 안 알려주면 보고가 아니다.
    try std.testing.expect(std.mem.indexOf(u8, hostGateReason(.windows, .ssh).?, "W9") != null);
}

// `printSmoke`가 PTY 안내를 띄울지와, `demo`가 오류 대신 실행될지는 **같은 사실** 하나에 달려 있다 —
// 이 빌드에 진짜 PTY 백엔드가 있는가. 그 사실을 OS 이름으로 다시 비교하지 않고 백엔드 선택에서 유도한다
// (`pty.backend_available`). 여기서는 **백엔드가 있는 호스트에 안내가 새지 않는 것**을 지킨다 — macOS CI에서
// 도는 단언이고, 깨지면 기존 사용자에게 없던 줄이 출력된다는 뜻이다.
test "PTY 안내는 백엔드가 있는 호스트에 새지 않는다" {
    if (builtin.os.tag == .macos) try std.testing.expect(maru.pty.backend_available);
    // 반대 방향 — "안내를 띄우는 호스트에서는 실행이 actual로 실패한다" — 은 그 사실이 사는 곳
    // (`src/pty/session.zig`)에서 spawn을 직접 불러 지킨다. 여기서 타입을 다시 비교하면 정의를 베껴 쓴
    // 동어반복이라 아무것도 못 잡는다.
}

/// `maru win32-editor-draw-smoke` — W8.3⒜⒝⒞1. **중립 편집기 뷰가 Windows 화면에 뜨고 굴러간다.**
///
/// §2m.6 이 파일 트리에서 세운 규율 그대로다: fixture 를 만들지 않고 **저장소 자신의 소스**를 연다.
/// 화면에 뜨는 것이 진짜 코드라야 "그럴듯한 그림" 과 "실제로 도는 것" 이 갈린다.
///
/// **중립 조각을 그대로 쓴다.** `editor_view` 는 이미 플랫폼 무관이고(`src/chrome/components/`),
/// ops → `DrawList` 낮추기도 CoreText 를 안 부른다(본문 참조 0 회 — §2m.6 과 같은 방식으로 쟀다).
/// 스크롤 상한도 중립이다(`editor_view.viewport.clampFirstRow`). 창부터 표현까지는
/// `win32_draw_host` 가 맡는다.
///
/// 편집기 선택 구간(문서 byte). **이름을 준다** — 익명 구조체는 리터럴마다 다른 타입이라 호출부와
/// 파라미터가 안 맞는다.
const editor_view = maru.chrome.components.editor_view;

const EditorSelRange = struct { lo: usize, hi: usize };

const EditorBuilt = struct {
    frame: maru.renderer.RenderFrame,
    written: editor_view.frame.Written,
    cells: std.ArrayList(d3d11_cells.Cell),
    ops_text: usize,
    ops_fill: usize,
    ops_dropped: usize,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.cells.deinit(a);
        self.frame.deinit(a);
    }
};

/// 확인 모달을 셀로 낮춰 **맨 위에** 얹는다. 그린 셀 수를 돌려준다(0 이면 안 그렸다).
///
/// **편집기와 같은 길을 쓴다** — `confirm.view` 가 내는 op 를 `buildTextDrawList` 로 글자로, 단색
/// 사각은 `appendSolidOps` 로. 모달은 창 좌표에 그려지므로 원점이 (0,0)이다.
fn appendConfirmCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    state: *const maru.chrome.components.confirm.State,
    p: maru.chrome.props.ChromeProps,
    tk: *const maru.chrome.Tokens,
    renderer_state: *maru.renderer.RendererState,
    builder: win32_terminal.FrameBuilder,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    frame_slot: *?maru.renderer.RenderFrame,
    confirm_unpainted_quads: *usize,
) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    defer ops.deinit(arena.allocator());
    try maru.chrome.components.confirm.view(state, p, tk, arena.allocator(), &ops);
    if (ops.items.len == 0) return 0;

    const cols: u16 = @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(1, p.metrics.backing_width_px / p.metrics.cell_width_px)));
    const rows: u16 = @intCast(@min(@as(u32, std.math.maxInt(u16)), @max(1, p.metrics.backing_height_px / p.metrics.cell_height_px)));
    const dl = try chrome_draw_lowering.buildTextDrawList(allocator, ops.items, tk, p.metrics.cell_width_px, p.metrics.cell_height_px, cols, rows);
    const frame = renderer_state.buildFrameFromDrawListWithRasterizer(allocator, dl, builder.shaper, builder.rasterizer) catch |err| {
        var l = dl;
        l.deinit(allocator);
        return err;
    };
    // **앞 프레임을 놓는다** — 매 프레임 새로 만드므로 안 놓으면 그만큼 샌다.
    if (frame_slot.*) |*old| old.deinit(allocator);
    frame_slot.* = frame;
    try draw_host.syncAtlasTexture(pipeline, renderer_state, atlas_w, atlas_h);
    _ = draw_host.uploadFrameRegions(pipeline, frame);

    // **버려지는 op 를 센다.** 이 셰이더에 그라디언트·테두리 계산이 없어 그런 quad 는 안 그려지는데,
    // 조용히 넘기면 "패널 없이 글자만 뜨는" 화면이 그럴듯해 보인다(실측으로 그랬다).
    for (ops.items) |op| switch (op) {
        // **그라디언트만 남았다.** 테두리는 이제 사각 넷으로 그린다(`appendSolidOps`).
        .quad => |q| if (q.gradient != .solid) {
            confirm_unpainted_quads.* += 1;
        },
        else => {},
    };
    const before = out.items.len;
    try appendSolidOps(allocator, ops.items, tk, p.metrics.backing_width_px, p.metrics.backing_height_px, 0, 0, out);
    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = blk: {
            const c = tk.get(.surface_fg);
            break :blk .{ .r = c.r, .g = c.g, .b = c.b };
        },
        .default_bg = blk2: {
            const c = tk.get(.surface_bg);
            break :blk2 .{ .r = c.r, .g = c.g, .b = c.b };
        },
    };
    const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(allocator, frame.glyph_quad_frame, frame.draw_list.cells, colors);
    defer allocator.free(native);
    try out.ensureUnusedCapacity(allocator, native.len);
    for (native) |n| out.appendAssumeCapacity(win32_terminal.cellFromNative(n, p.metrics.cell_width_px, p.metrics.cell_height_px, atlas_w.*, atlas_h.*));
    return out.items.len - before;
}

/// `draw.Op` 의 **단색 사각**(fill·solid quad)을 셀로 낮춘다. 글리프는 호출자가 따로 넣는다 —
/// 그리는 순서가 곧 z 순서라 사각이 **먼저**여야 한다.
///
/// **한 곳에 둔다.** 편집기와 확인 모달이 같은 op 스트림을 쓰는데, 이 루프를 각자 적으면 그라디언트·
/// 테두리를 세는 규칙(아래)이 한쪽만 바뀌는 날 화면이 조용히 갈린다.
fn appendSolidOps(
    a: std.mem.Allocator,
    ops: []const maru.chrome.draw.Op,
    tk: *const maru.chrome.Tokens,
    clip_w: u32,
    clip_h: u32,
    origin_x: u32,
    origin_y: u32,
    out: *std.ArrayList(d3d11_cells.Cell),
) !void {
    for (ops) |op| {
        // **테두리는 사각 넷으로 그린다.** 이 셰이더에 테두리 계산은 없지만 `border_widths` 가
        // 변마다 두께를 주므로 단색 사각으로 정확히 같은 그림이 된다 — 확인 모달의 패널 테두리가
        // 통째로 빠져 글자만 떠 있던 것이 그래서였다(실측: 버려진 quad 4 개).
        //
        // **그라디언트는 여전히 안 그린다** — 그것은 단색으로 근사하면 화면이 틀린 채로 그럴듯해진다.
        if (op == .quad) {
            const q = op.quad;
            if (q.gradient == .solid) {
                if (q.border_role) |br| {
                    const bc = tk.get(br);
                    const bargb = (@as(u32, q.alpha) << 24) | (@as(u32, bc.r) << 16) | (@as(u32, bc.g) << 8) | bc.b;
                    // 위·아래·왼쪽·오른쪽 순서(`border_widths` 의 규약).
                    const edges = [4]maru.chrome.draw.Rect{
                        .{ .x = q.rect.x, .y = q.rect.y, .w = q.rect.w, .h = q.border_widths[0] },
                        .{ .x = q.rect.x, .y = q.rect.y + @as(i32, @intCast(q.rect.h -| q.border_widths[1])), .w = q.rect.w, .h = q.border_widths[1] },
                        .{ .x = q.rect.x, .y = q.rect.y, .w = q.border_widths[2], .h = q.rect.h },
                        .{ .x = q.rect.x + @as(i32, @intCast(q.rect.w -| q.border_widths[3])), .y = q.rect.y, .w = q.border_widths[3], .h = q.rect.h },
                    };
                    for (edges) |e| {
                        if (e.w == 0 or e.h == 0) continue;
                        const ex0 = @max(e.x, 0);
                        const ey0 = @max(e.y, 0);
                        const ex1 = @min(e.x + @as(i32, @intCast(e.w)), @as(i32, @intCast(clip_w)));
                        const ey1 = @min(e.y + @as(i32, @intCast(e.h)), @as(i32, @intCast(clip_h)));
                        if (ex1 <= ex0 or ey1 <= ey0) continue;
                        try out.append(a, d3d11_cells.solidCell(
                            @floatFromInt(ex0 + @as(i32, @intCast(origin_x))),
                            @floatFromInt(ey0 + @as(i32, @intCast(origin_y))),
                            @floatFromInt(ex1 - ex0),
                            @floatFromInt(ey1 - ey0),
                            d3d11_cells.colorFromArgb(bargb),
                            .{ 0, 0, 0, 0 },
                        ));
                    }
                }
            }
        }
        const rect: maru.chrome.draw.Rect, const role: maru.chrome.tokens.ColorRole, const alpha: u8, const radii: [4]u16 = switch (op) {
            .fill => |f| .{ f.rect, f.role, f.alpha, .{ 0, 0, 0, 0 } },
            // **그라디언트는 아직 없다** — 단색으로 근사하면 화면이 틀린 채로 그럴듯해진다.
            .quad => |q| if (q.gradient == .solid)
                .{ q.rect, q.fill_role, q.alpha, q.corner_radii }
            else
                continue,
            else => continue,
        };
        const x0 = @max(rect.x, 0);
        const y0 = @max(rect.y, 0);
        const x1 = @min(rect.x + @as(i32, @intCast(rect.w)), @as(i32, @intCast(clip_w)));
        const y1 = @min(rect.y + @as(i32, @intCast(rect.h)), @as(i32, @intCast(clip_h)));
        if (x1 <= x0 or y1 <= y0) continue;
        const rgb = tk.get(role);
        const argb = (@as(u32, alpha) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
        try out.append(a, d3d11_cells.solidCell(
            @floatFromInt(x0 + @as(i32, @intCast(origin_x))),
            @floatFromInt(y0 + @as(i32, @intCast(origin_y))),
            @floatFromInt(x1 - x0),
            @floatFromInt(y1 - y0),
            d3d11_cells.colorFromArgb(argb),
            .{ @floatFromInt(radii[0]), @floatFromInt(radii[1]), @floatFromInt(radii[2]), @floatFromInt(radii[3]) },
        ));
    }
}

/// 편집기 프레임에 필요한 렌더 자원. **스모크는 `draw_host.Host` 가, 합성 루프는 흩어져 있는 자기
/// 상태가 준다** — 둘이 같은 조립을 쓰게 하는 이음매다.
///
/// **`renderer_state` 를 포인터로 받는다.** 값으로 받으면 합성 루프에 아틀라스 상태가 하나 더 생겨,
/// 편집기가 구운 글리프를 터미널이 못 보고 UV 가 갈린다.
const EditorHost = struct {
    renderer_state: *maru.renderer.RendererState,
    shaper: win32_text.Shaper,
    rasterizer: win32_text.NeutralRasterizer,
    pipeline: *d3d11_cells.CellPipeline,
    atlas_w: *u32,
    atlas_h: *u32,
    cell_w: u32,
    cell_h: u32,

    fn fromHost(h: *draw_host.Host) EditorHost {
        return .{
            .renderer_state = &h.renderer_state,
            .shaper = h.shaper,
            .rasterizer = h.rasterizer,
            .pipeline = h.pipeline,
            .atlas_w = &h.atlas_w,
            .atlas_h = &h.atlas_h,
            .cell_w = h.cell_w,
            .cell_h = h.cell_h,
        };
    }

    /// `Host.prepare` 가 하던 것 — 프레임을 짓고 아틀라스를 맞추고 새 글리프를 올린다. 셋을 한
    /// 자리에 묶어 둔다: 하나라도 빠지면 글자가 **엉뚱한 UV** 를 가리킨다(그 함수 doc).
    fn prepare(self: EditorHost, a: std.mem.Allocator, draw_list: maru.renderer.DrawList) !maru.renderer.RenderFrame {
        var list = draw_list;
        var frame = self.renderer_state.buildFrameFromDrawListWithRasterizer(a, list, self.shaper, self.rasterizer) catch |err| {
            list.deinit(a);
            return err;
        };
        errdefer frame.deinit(a);
        try draw_host.syncAtlasTexture(self.pipeline, self.renderer_state, self.atlas_w, self.atlas_h);
        _ = draw_host.uploadFrameRegions(self.pipeline, frame);
        return frame;
    }

    fn appendGlyphCellsAt(
        self: EditorHost,
        a: std.mem.Allocator,
        frame: maru.renderer.RenderFrame,
        colors: maru.renderer.metal_frame.CellColors,
        origin_x: u32,
        origin_y: u32,
        cells: *std.ArrayList(d3d11_cells.Cell),
    ) !usize {
        const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(a, frame.glyph_quad_frame, frame.draw_list.cells, colors);
        defer a.free(native);
        maru.renderer.metal_frame.setCellsPaneOrigin(native, origin_x, origin_y);
        try cells.ensureUnusedCapacity(a, native.len);
        for (native) |n| cells.appendAssumeCapacity(win32_terminal.cellFromNative(n, self.cell_w, self.cell_h, self.atlas_w.*, self.atlas_h.*));
        return native.len;
    }
};

/// 편집기 한 프레임을 짓는다 — **스모크와 제품이 같은 함수를 쓴다.**
///
/// 예전에는 이 조립이 `win32-editor-draw-smoke` 안의 클로저였다. 합성 창에 편집기를 붙이며 그대로
/// 두 벌이 될 뻔했는데, 그러면 스크롤한 프레임과 첫 프레임이 갈리던 그 실패(그 클로저 머리말)가
/// **플랫폼 두 곳 사이**에서 다시 난다.
///
/// `origin_x`·`origin_y` 는 이 프레임이 창의 어느 픽셀에 앉는가다 — 스모크는 (0,0), 제품은
/// 터미널 사각형의 왼쪽 위다.
fn buildEditorFrame(
    a: std.mem.Allocator,
    h: EditorHost,
    first_line: usize,
    ls: []const []const u8,
    sc: anytype,
    op_buf: []maru.chrome.draw.Op,
    tk: *const maru.chrome.Tokens,
    cl: maru.renderer.metal_frame.CellColors,
    v: maru.chrome.draw.Rect,
    inn: maru.chrome.draw.Rect,
    cw: u32,
    ch: u32,
    g: maru.terminal.Size,
    /// 배경 사각. **호출자가 준다** — 스모크는 내용을 창 (0,0) 에 놓아 배경이 음수로 시작해야 하고,
    /// 제품은 pane 원점에 딱 맞는다. 그 산수를 여기 두면 둘 중 하나가 반드시 틀린다.
    bg: maru.chrome.draw.Rect,
    origin_x: u32,
    origin_y: u32,
    first_col: u16,
    content_max_cols: ?u32,
    sel: ?EditorSelRange,
    ss: anytype,
) !EditorBuilt {
    // **선택을 행 축으로 자른다.** 산술은 중립이 소유한다(`selection_marks`) — macOS 와
    // Windows 가 각자 적으면 경계 셋(줄 시작·줄 끝·선택 양끝) 중 하나가 조용히 갈린다.
    //
    // 행 → 문서 줄 대응은 **여기서** 푼다(랩·접힘이 없으므로 순차다). 그것이 축을 정하는
    // 일이고, 그 파일 머리말이 호출자 몫이라고 적어 둔 자리다.
    var sel_marks: ?[]const []const editor_view.frame.Mark = null;
    if (sel) |sr| {
        const n = @min(ss.rows.len, ls.len -| first_line);
        for (0..n) |i| {
            const li = first_line + i;
            ss.spans[i] = .{ .start = ss.line_starts[li], .end = ss.line_starts[li] + ls[li].len };
        }
        editor_view.selection_marks.build(sr.lo, sr.hi, ss.spans[0..n], ss.rows[0..n], ss.buf[0..n]);
        sel_marks = ss.rows[0..n];
    }

    const w = editor_view.diff_frame.buildSide(
        .{
            .lines = ls,
            .total_lines = ls.len,
            .selection_marks = sel_marks,
            // 가로 스크롤은 **쪽마다**다(그 필드 doc: 공유하면 반대쪽이 엉뚱한 곳을 본다).
            .first_col = first_col,
            // 가장 긴 줄의 표시 폭 — 막대 길이와 "막대를 세울지" 를 중립이 이것으로 정한다.
            .content_max_cols = content_max_cols,
        },
        .{
            .first_line = first_line,
            // **랩은 토글이고 기본은 끔**(`native-editor-visual-mapping.md`) — 그래서 가로 스크롤이
            // 축이 되고, 중립이 그 축으로 막대를 세운다(`showsHorizontalBar`).
            .wrap = false,
            .tab_width = 4,
            .cell_w_px = @intCast(cw),
            .cell_h_px = @intCast(ch),
            .font_px = @intCast(ch),
        },
        inn,
        // **배경 사각은 호출자가 준다**(위 파라미터 doc).
        bg,
        sc,
    );

    // **낮추기가 무엇을 버리는지 센다.** `buildTextDrawList` 는 이름 그대로 **글자만** 셀로
    // 만든다. 세지 않으면 "그림이 그럴듯하다" 로 넘어가고, 실제로 스크롤바가 통째로 빠진 것을
    // 못 본다(이 스모크를 쓰면서 그렇게 한 번 넘길 뻔했다).
    var n_text: usize = 0;
    var n_fill: usize = 0;
    var n_drop: usize = 0;
    for (op_buf[0..w.ops]) |op| switch (op) {
        .text => n_text += 1,
        .fill, .quad => n_fill += 1,
        .clip => {},
        else => n_drop += 1,
    };

    const dl = try chrome_draw_lowering.buildTextDrawList(a, op_buf[0..w.ops], tk, cw, ch, g.cols, g.rows);
    const frame_built = try h.prepare(a, dl);
    var built = EditorBuilt{
        .frame = frame_built,
        .written = w,
        .cells = .empty,
        .ops_text = n_text,
        .ops_fill = n_fill,
        .ops_dropped = n_drop,
    };
    errdefer built.deinit(a);

    // **단색 사각(배경·스크롤바)을 글리프보다 먼저 넣는다** — 그리는 순서가 곧 z 순서다.
    try appendSolidOps(a, op_buf[0..w.ops], tk, v.w, v.h, origin_x, origin_y, &built.cells);
    _ = try h.appendGlyphCellsAt(a, built.frame, cl, origin_x, origin_y, &built.cells);
    return built;
}

/// **색은 리터럴이다.** §2m.17 이 "스모크에 config 가 끼면 판정이 흐려진다" 로 정해 둔 규율이다.
fn runWin32EditorDrawSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-editor-draw-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    var loaded = try maru.config.loader.loadDefault(io, allocator);
    defer loaded.deinit();
    const cfg = loaded.config;

    var host = draw_host.Host.open(allocator, cfg, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W8.3 editor)"),
    }) catch {
        try draw_host.reportSetupFailure(stderr, "win32-editor-draw-smoke");
        return error.UnknownCommand;
    };
    defer host.close();
    const cell_w = host.cell_w;
    const cell_h = host.cell_h;
    const grid = host.grid();

    // ── 진짜 파일을 연다 ─────────────────────────────────────────────────────────────────────
    //
    // 이 저장소의 소스 하나를 고른다. 한글 주석과 ASCII 코드가 섞여 있어 폴백 경로도 함께 탄다.
    const doc_path = "src/text_shaper.zig";
    const source = std.Io.Dir.cwd().readFileAlloc(io, doc_path, allocator, .limited(4 << 20)) catch |err| {
        try stderr.print("maru win32-editor-draw-smoke: could not read {s}({s})\n", .{ doc_path, @errorName(err) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer allocator.free(source);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, source, 0x0A);
        while (it.next()) |raw| {
            // CRLF 를 여기서 벗긴다 — 편집기 뷰는 표시 텍스트를 받는다.
            try lines.append(allocator, std.mem.trimEnd(u8, raw, "\r"));
        }
    }

    // **줄 시작 offset.** 선택은 문서 offset 축이라 줄 텍스트만으로는 못 자른다. 파일을 개행으로
    // 나눴으므로 누적합이 곧 시작이고, `+ 1` 이 개행 한 바이트다(CRLF 는 위에서 CR 을 벗겼지만
    // 원본에는 두 바이트라, 그 파일에서는 이 값이 한 바이트씩 밀린다 — 아래 판정이 같은 축을 쓰므로
    // 자기 일관적이고, 문서 모델이 붙으면 그쪽이 진짜 값을 준다).
    const line_starts = try allocator.alloc(usize, lines.items.len);
    defer allocator.free(line_starts);
    {
        var off: usize = 0;
        for (lines.items, line_starts) |l, *st| {
            st.* = off;
            off += l.len + 1;
        }
    }

    // ── scratch ──────────────────────────────────────────────────────────────────────────────
    const ops = try allocator.alloc(maru.chrome.draw.Op, 4096);
    defer allocator.free(ops);
    const text_bytes = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(text_bytes);
    const runs = try allocator.alloc(maru.chrome.draw.Run, 4096);
    defer allocator.free(runs);
    const content_rows = try allocator.alloc(editor_view.content.Row, 512);
    defer allocator.free(content_rows);
    const visual_rows = try allocator.alloc(editor_view.visual_map.VisualRow, 512);
    defer allocator.free(visual_rows);
    const gutter_rows = try allocator.alloc(editor_view.gutter.Row, 512);
    defer allocator.free(gutter_rows);
    const row_counts = try allocator.alloc(u32, lines.items.len + 1);
    defer allocator.free(row_counts);
    const count_scratch = try allocator.alloc(u8, editor_view.content.count_scratch_bytes);
    defer allocator.free(count_scratch);

    // 선택 마크 저장소. 행 수만큼이면 되지만 창이 커질 여지를 조금 둔다.
    const sel_cap = @as(usize, grid.rows) + 2;
    const sel_rows = try allocator.alloc([]const editor_view.frame.Mark, sel_cap);
    defer allocator.free(sel_rows);
    const sel_buf = try allocator.alloc(editor_view.frame.Mark, sel_cap);
    defer allocator.free(sel_buf);
    const sel_spans = try allocator.alloc(editor_view.selection_marks.Span, sel_cap);
    defer allocator.free(sel_spans);
    // **이름을 준다.** 익명 구조체는 리터럴마다 다른 타입이라 호출부와 파라미터가 안 맞는다.
    const SelScratch = struct {
        line_starts: []const usize,
        rows: [][]const editor_view.frame.Mark,
        buf: []editor_view.frame.Mark,
        spans: []editor_view.selection_marks.Span,
    };
    const sel_scratch = SelScratch{ .line_starts = line_starts, .rows = sel_rows, .buf = sel_buf, .spans = sel_spans };

    const scratch = editor_view.frame.Scratch{
        .ops = ops,
        .text_bytes = text_bytes,
        .runs = runs,
        .content_rows = content_rows,
        .visual_rows = visual_rows,
        .gutter_rows = gutter_rows,
        .row_counts = row_counts,
        .count_scratch = count_scratch,
    };

    // 뷰 사각은 **클라이언트 전체**다. 제품은 pane 기하에서 오지만 스모크에는 pane 이 없다.
    //
    // **격자 크기(`cols*cell_w`)로 잡으면 안 된다.** 창은 셀 크기의 배수가 아니라 오른쪽·아래에
    // 자투리가 남고(884×581 vs 격자 882×570), 그러면 **배경 quad 가 그 띠를 안 덮는다.** clear
    // color 가 배경색과 같아서 안 보였다 — 초록 대조군에서 정확히 그만큼인 16,656 px 이 드러났다.
    const view: maru.chrome.draw.Rect = .{
        .x = 0,
        .y = 0,
        .w = host.initial.width_px,
        .h = host.initial.height_px,
    };
    const inset: i32 = @intCast(editor_view.frame.content_inset_px);
    // **스모크는 내용을 창 (0,0) 에 놓는다** — 그래서 배경이 음수로 시작하고 그만큼 폭·높이도
    // 늘어야 오른쪽·아래가 안 빈다(초록 대조군 5,844 px). 제품은 pane 원점에 딱 맞는 사각을 준다.
    const smoke_editor_bg: maru.chrome.draw.Rect = .{
        .x = -inset,
        .y = -inset,
        .w = host.initial.width_px + editor_view.frame.content_inset_px * 2,
        .h = host.initial.height_px + editor_view.frame.content_inset_px * 2,
    };
    const inner: maru.chrome.draw.Rect = .{
        .x = 0,
        .y = 0,
        .w = view.w -| editor_view.frame.content_inset_px * 2,
        .h = view.h -| editor_view.frame.content_inset_px * 2,
    };

    // **색은 리터럴이다**(위 doc).
    const tokens = chromeTokensFor(cfg);
    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 },
        .default_bg = .{ .r = 0x1E, .g = 0x24, .b = 0x30 },
    };

    // **clear color 를 배경색과 일부러 다르게 둔다.** 같게 두면 배경 quad 가 어디를 안 덮어도
    // 화면이 멀쩡해 보인다 — 실제로 그렇게 두 번 숨었다(격자 크기로 잡은 뷰 16,656 px, 배경
    // 폭을 안 늘린 것 5,844 px). 마젠타면 안 덮인 자리가 캡처에서 **소리를 지른다.**
    const clear_argb: u32 = 0xFFFF00FF;

    // ── 한 프레임 ────────────────────────────────────────────────────────────────────────────
    //
    // 스크롤이 붙으면서 프레임이 **여러 번** 만들어진다. 그래서 조립을 한 자리에 모은다 — 두 군데에
    // 적으면 스크롤한 프레임과 첫 프레임이 조용히 갈린다.

    // **그려진 셀에서 글자를 도로 읽어** 그 행에 파일의 그 줄이 있는지 본다(§2m.6 의 규율).
    //
    // **전제 둘 — 깨지면 거짓으로 실패한다.** ⒜ `wrap = false` 라 시각 행 N 이 논리 줄
    // `first_line + N` 이다 ⒝ 줄 **안쪽**에 탭이 없다(렌더는 탭을 열로 펼치는데 비교 대상은 원본).
    const judge = struct {
        fn rows(a: std.mem.Allocator, f: maru.renderer.RenderFrame, ls: []const []const u8, first_line: usize, visible: usize) !struct { checked: usize, matched: usize } {
            var row_text: std.ArrayList(u8) = .empty;
            defer row_text.deinit(a);
            var checked: usize = 0;
            var matched: usize = 0;
            var row: u16 = 0;
            while (row < visible and first_line + row < ls.len) : (row += 1) {
                const want = std.mem.trim(u8, ls[first_line + row], " \t");
                // **짧은 줄은 판정에서 뺀다.** `//!` 처럼 흔한 접두는 아무 행에나 있어서 "맞았다" 가
                // 아무 말도 아니게 된다 — 한 줄 밀어 그리는 뮤턴트가 28/28 에서 6/28 로만 떨어졌고
                // 그 6 이 전부 이 부류였다.
                if (want.len < 8) continue;
                row_text.clearRetainingCapacity();
                for (f.draw_list.cells) |c| {
                    if (c.row != row) continue;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(c.codepoint), &buf) catch continue;
                    try row_text.appendSlice(a, buf[0..n]);
                }
                checked += 1;
                const head = want[0..@min(want.len, 24)];
                if (std.mem.indexOf(u8, row_text.items, head) != null) matched += 1;
            }
            return .{ .checked = checked, .matched = matched };
        }
    }.rows;

    // ── 클릭 판정 ────────────────────────────────────────────────────────────────────────────
    //
    // **그려진 글자가 곧 클릭이 답한 글자인가**(macOS ADV3-A 와 같은 판정). 셀에서 글자를 도로 읽어
    // 그 셀 한가운데를 찍고, 히트테스트가 준 byte 의 글자가 **같은지** 본다.
    //
    // 히트테스트 계산은 중립이 소유한다(`editor_view.hit.bodyPoint`) — macOS `hitTestBody` 가 쓰던
    // 그 함수 그대로다. Windows 가 하는 일은 **굳힌 기하와 행 표를 모아 넘기는 것**뿐이다.
    const clickJudge = struct {
        fn run(
            a: std.mem.Allocator,
            ev: type,
            f: maru.renderer.RenderFrame,
            rows: []const maru.chrome.ui.visual_map.VisualRow,
            ls: []const []const u8,
            first: usize,
            visible: usize,
            cw: u32,
            ch: u32,
            total_cols: u16,
        ) !struct { checked: usize, matched: usize, wide: usize } {
            // 행 → 원본 논리 줄. **랩·접힘이 없으므로 순차다** — 둘 중 하나라도 켜면 이 표를
            // 렌더가 만들어 줘야 한다(macOS `editor_hit_lines` 가 그 자리다).
            const row_lines = try a.alloc(u32, visible);
            defer a.free(row_lines);
            for (row_lines, 0..) |*rl, i| rl.* = @intCast(first + i);

            const layout = ev.geometry.compute(total_cols, ls.len, .{});
            const geom = ev.hit.Geometry{
                .body_x = 0,
                .body_y = 0,
                .content_left_px = @as(u32, layout.contentLeft()) * cw,
                .content_width = layout.content.width,
                .cell_w_px = @intCast(cw),
                .cell_h_px = @intCast(ch),
                .tab_width = 4,
            };

            var checked: usize = 0;
            var n_wide: usize = 0;
            var matched: usize = 0;
            for (f.draw_list.cells) |c| {
                if (c.row >= visible) continue;
                if (c.col < layout.contentLeft()) continue; // gutter 는 이 판정의 것이 아니다
                if (c.codepoint == ' ' or c.codepoint == 0) continue;
                if (c.codepoint >= 128) n_wide += 1;
                // **셀의 왼쪽 안쪽을 찍는다.** `byteAtPoint` 는 *"어느 글자 위인가"* 가 아니라
                // *"caret 이 어디로 가는가"* 를 답한다 — 왼쪽 절반이면 그 글자 **앞**, 오른쪽
                // 절반이면 **뒤**다. 한가운데(`lo + cw/2`)는 정확히 그 경계라 다음 글자로 넘어간다.
                //
                // 실측으로 걸렸다: 한가운데를 찍었더니 1822/5454 만 맞았고 어긋난 것이 전부 한 칸씩
                // 밀려 있었다. **판정이 틀린 것이지 히트테스트가 틀린 것이 아니다.**
                const x: f64 = @floatFromInt(@as(u32, c.col) * cw + 1);
                const y: f64 = @floatFromInt(@as(u32, c.row) * ch + ch / 2);
                const p = ev.hit.bodyPoint(geom, rows[0..visible], row_lines, ls, x, y) orelse continue;
                checked += 1;
                const text = ls[p.line];
                if (p.byte_in_line >= text.len) continue;
                const len = std.unicode.utf8ByteSequenceLength(text[p.byte_in_line]) catch continue;
                if (p.byte_in_line + len > text.len) continue;
                const cp = std.unicode.utf8Decode(text[p.byte_in_line..][0..len]) catch continue;
                if (cp == c.codepoint) matched += 1;
            }
            return .{ .checked = checked, .matched = matched, .wide = n_wide };
        }
    }.run;

    // ── 스크롤 대본 ──────────────────────────────────────────────────────────────────────────
    //
    // **사람이 없어도 판정된다.** 실기 휠은 아래 루프가 받지만, 그것만으로는 자동 실행에서 스크롤이
    // 도는지 알 수 없다 — 대본을 태워 각 단계마다 **보이는 첫 줄이 실제로 그 줄인지** 확인한다.
    // 상한 두 자리(0 아래, 끝 위)도 함께 민다.
    var first_line: usize = 0;
    var script_steps: usize = 0;
    // 실제로 **잴 것이 있었던** 단계 수. `script_steps` 와 다를 수 있다 — 8 바이트 넘는 줄이 화면에
    // 하나도 없으면(빈 파일·짧은 줄만 있는 파일) 판정할 것이 없다.
    //
    // **"실패" 와 "판정 불가" 를 가른다.** 처음엔 `script_ok/script_steps` 만 냈는데, 빈 파일로
    // 돌려 보니 `0/6` 이 나와 스크롤이 깨진 것처럼 보였다 — 실제로는 잴 줄이 없었을 뿐이다.
    var script_judged: usize = 0;
    var script_ok: usize = 0;
    var click_checked: usize = 0;
    var click_matched: usize = 0;
    // **2 칸 글자를 몇 개나 쟀나.** 안 세면 한글이 조용히 빠져도 분모만 보고는 모른다 —
    // 적대적 검증에서 실제로 물어본 것이라 보고에 남긴다(5,454 중 1,613 이 2 칸이다).
    var click_wide: usize = 0;
    // 본문이 쓰는 열 수 — 히트테스트 layout 이 gutter 폭을 그 값에서 낸다. `buildSide` 가 안에서
    // 쓰는 것과 **같은 함수**로 구한다(다른 값을 쓰면 gutter 경계가 그림과 갈린다).
    const side_cols = editor_view.diff_frame.sideMetrics(inner.w, inner.h, @intCast(cell_w), @intCast(cell_h)).total_cols;
    var clamp_top_ok = false;
    var clamp_bottom_ok = false;

    // **스크롤 상한은 컴포넌트가 준 값을 쓴다** — `Written.max_top_line`. 그 필드 doc 이
    // *"입력이 이것을 읽는다"* 고 못 박았고 macOS 도 그것을 굳혀 뒀다가 clamp 에 쓴다
    // (`app_session/editor.zig` 의 `editor_max_top_line`).
    //
    // `viewport.clampFirstRow(.., lines.len, rows)` 로 따로 세면 **두 번째 출처**가 된다. 랩이
    // 꺼져 있으면 값이 같아 지금은 안 갈리지만, 랩을 켜는 순간 논리 줄 수와 시각 행 수가 달라져
    // 조용히 어긋난다 — 그 필드 doc 이 경고하는 자리가 정확히 이것이다.
    var max_top: usize = 0;
    {
        var probe = try buildEditorFrame(allocator, EditorHost.fromHost(&host), 0, lines.items, scratch, ops, &tokens, colors, view, inner, cell_w, cell_h, grid, smoke_editor_bg, 0, 0, 0, null, null, sel_scratch);
        defer probe.deinit(allocator);
        max_top = probe.written.max_top_line;
    }
    {
        for ([_]isize{ 0, 5, 20, -3, 10_000, -10_000 }) |delta| {
            const before = first_line;
            first_line = if (delta >= 0)
                @min(before + @as(usize, @intCast(delta)), max_top)
            else
                before -| @as(usize, @intCast(-delta));

            var built = try buildEditorFrame(allocator, EditorHost.fromHost(&host), first_line, lines.items, scratch, ops, &tokens, colors, view, inner, cell_w, cell_h, grid, smoke_editor_bg, 0, 0, 0, null, null, sel_scratch);
            defer built.deinit(allocator);
            const r = try judge(allocator, built.frame, lines.items, first_line, built.written.visual_rows);
            script_steps += 1;
            if (r.checked == 0) continue; // 잴 것이 없다 — 아래 상한 판정도 성립하지 않는다
            script_judged += 1;
            if (r.matched == r.checked) script_ok += 1;

            // **스크롤한 자리에서도 클릭이 맞아야 한다.** first_line 을 안 더하면 여기서 걸린다 —
            // 화면 첫 행에서만 재면 그 결함이 안 드러난다.
            const ck = try clickJudge(
                allocator,
                editor_view,
                built.frame,
                visual_rows,
                lines.items,
                first_line,
                built.written.visual_rows,
                cell_w,
                cell_h,
                side_cols,
            );
            click_checked += ck.checked;
            click_matched += ck.matched;
            click_wide += ck.wide;
            // **상한은 내용으로 잰다.** `first_line == maxFirstRow(..)` 로 재면 `clampFirstRow` 를
            // `maxFirstRow` 로 확인하는 셈이라 동어반복이다 — 둘 다 같은 모듈의 같은 계산에서 온다.
            // 대신 "끝까지 내리면 **마지막 줄이 화면에 있다**" 를 본다: 그리는 쪽과 세는 쪽이
            // 갈리면 여기서 걸린다.
            if (delta == -10_000) clamp_top_ok = (first_line == 0 and r.matched == r.checked);
            if (delta == 10_000) clamp_bottom_ok =
                (first_line + built.written.visual_rows >= lines.items.len and r.matched == r.checked);
        }
        first_line = 0;
    }

    // ── 선택 판정 ────────────────────────────────────────────────────────────────────────────
    //
    // **띠가 그려진 행이 곧 선택이 덮는 행인가.** 마크만 보면 중립 함수를 자기 자신으로 확인하는
    // 셈이라(그쪽에 이미 테스트 일곱이 있다), 여기서는 **렌더가 낸 op** 을 본다 — 마크 → `paintSelection`
    // → 사각 op 까지 이어졌는지가 이 판정의 대상이다.
    var sel_rows_drawn: usize = 0;
    var sel_rows_want: usize = 0;
    var sel_rows_match = false;
    var sel_first_cols: u32 = 0;
    var sel_last_cols: u32 = 0;
    {
        // 3 번 줄 5 바이트에서 6 번 줄 2 바이트까지.
        const lo = line_starts[3] + 5;
        const hi = line_starts[6] + 2;
        var built_sel = try buildEditorFrame(allocator, EditorHost.fromHost(&host), 0, lines.items, scratch, ops, &tokens, colors, view, inner, cell_w, cell_h, grid, smoke_editor_bg, 0, 0, 0, null, .{ .lo = lo, .hi = hi }, sel_scratch);
        defer built_sel.deinit(allocator);

        // **기대값을 여기서 따로 센다** — 중립 함수를 안 부르고, 줄 범위가 겹치는지만 본다.
        for (3..7) |li| {
            const st = line_starts[li];
            const en = st + lines.items[li].len;
            if (en > lo and st < hi and @min(hi, en) > @max(lo, st)) sel_rows_want += 1;
        }

        // 그려진 띠: 한 행 높이짜리 사각 중 배경(음수 y)·스크롤바(폭 8)를 뺀 것.
        //
        // **행 수만 세면 부족하다.** 양끝이 잘린 선택인데 통째로 칠해도 개수는 같다 — `lo` 나 `hi`
        // 를 무시하는 뮤턴트가 그대로 통과한다. 그래서 **첫 띠와 끝 띠의 폭**까지 본다.
        var first_band: ?maru.chrome.draw.Rect = null;
        var last_band: ?maru.chrome.draw.Rect = null;
        for (ops[0..built_sel.written.ops]) |op| {
            const rect: maru.chrome.draw.Rect = switch (op) {
                .fill => |f| f.rect,
                .quad => |q| q.rect,
                else => continue,
            };
            if (rect.y < 0) continue; // 배경
            if (rect.h != cell_h) continue; // 스크롤바는 여러 행 높이다
            if (rect.w < cell_w) continue; // 한 칸도 안 되는 것은 띠가 아니다
            sel_rows_drawn += 1;
            if (first_band == null) first_band = rect;
            last_band = rect;
        }
        // ⒜ 첫 띠는 **줄 처음이 아니라 5 바이트 뒤**에서 시작한다(`lo` 를 무시하면 왼쪽에 붙는다).
        // ⒝ 끝 띠는 **2 칸**이다(`hi` 를 무시하면 줄 끝까지 늘어난다).
        const fb = first_band orelse maru.chrome.draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const lb = last_band orelse maru.chrome.draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        sel_first_cols = @divTrunc(fb.w, cell_w);
        sel_last_cols = @divTrunc(lb.w, cell_w);
        const lo_honored = fb.x > @as(i32, @intCast(@as(u32, @intCast(editor_view.geometry.compute(side_cols, lines.items.len, .{}).contentLeft())) * cell_w));
        const hi_honored = sel_last_cols == 2;
        sel_rows_match = (sel_rows_drawn == sel_rows_want and sel_rows_want > 0 and lo_honored and hi_honored);
    }

    // ── 실기 루프 ────────────────────────────────────────────────────────────────────────────
    var drag_anchor: ?usize = null;
    var sel_range: ?EditorSelRange = null;
    var caret_at: ?editor_view.hit.Point = null;
    var built = try buildEditorFrame(allocator, EditorHost.fromHost(&host), first_line, lines.items, scratch, ops, &tokens, colors, view, inner, cell_w, cell_h, grid, smoke_editor_bg, 0, 0, 0, null, sel_range, sel_scratch);
    defer built.deinit(allocator);
    var frames: usize = 0;
    var wheel_events: usize = 0;
    var closed = false;
    // 휠 나머지. **누적 규칙은 `win32_mouse.wheelLines` 가 소유한다** — 여기 인라인으로 적으면
    // 터미널이 같은 것을 또 적게 되고 둘이 갈린다(그 함수에 테스트 넷이 붙어 있다).
    var wheel_remainder: i32 = 0;
    // 드래그 선택. **anchor 는 누른 자리, focus 는 지금 자리**다 — 위로 끌면 `focus < anchor` 라
    // 그리기 전에 정렬한다(`session.editor.selection.Selection` 이 같은 규율을 쓴다).
    var click_events: usize = 0;
    var drag_moves: usize = 0;
    // **프레임 수에 근거를 둔다** — build step 이 반복해서 도는데 그때마다 창이 오래 차지하면 안 된다.
    // 120 프레임(약 3.5 초)이면 반복 표현·크기 변경을 보기에도 스크린샷을 잡기에도 족하다.
    while (frames < 120 and !host.quitting() and !closed) : (frames += 1) {
        var scroll: isize = 0;
        var dirty = false;
        for (try host.poll()) |ev| switch (ev) {
            .close_requested => closed = true,
            .mouse => |m| if (m.kind == .left_down or (m.kind == .moved and drag_anchor != null) or m.kind == .left_up) {
                if (m.kind == .left_down) click_events += 1;
                if (m.kind == .moved) drag_moves += 1;
                const row_lines = allocator.alloc(u32, built.written.visual_rows) catch continue;
                defer allocator.free(row_lines);
                for (row_lines, 0..) |*rl, i| rl.* = @intCast(first_line + i);
                const layout = editor_view.geometry.compute(side_cols, lines.items.len, .{});
                const p = editor_view.hit.bodyPoint(.{
                    .body_x = 0,
                    .body_y = 0,
                    .content_left_px = @as(u32, layout.contentLeft()) * cell_w,
                    .content_width = layout.content.width,
                    .cell_w_px = @intCast(cell_w),
                    .cell_h_px = @intCast(cell_h),
                    .tab_width = 4,
                }, visual_rows[0..built.written.visual_rows], row_lines, lines.items, @floatFromInt(m.x_px), @floatFromInt(m.y_px));
                if (p) |pt| {
                    const off = line_starts[pt.line] + pt.byte_in_line;
                    caret_at = pt;
                    if (m.kind == .left_down) {
                        drag_anchor = off;
                        sel_range = null; // 누른 순간은 caret 뿐이다
                    } else if (drag_anchor) |a| {
                        sel_range = if (off == a) null else .{ .lo = @min(a, off), .hi = @max(a, off) };
                    }
                }
                if (m.kind == .left_up) drag_anchor = null;
                dirty = true;
            } else if (m.kind == .wheel) {
                wheel_events += 1;
                // 양수 델타 = 위로 굴림(Windows 규약) → 화면은 위로, 즉 `first_line` 이 준다.
                scroll -= win32_mouse.wheelLines(&wheel_remainder, m.wheel_delta, win32_mouse.default_lines_per_notch);
            },
            .key => |k| switch (k.key) {
                .page_down => scroll += @intCast(grid.rows),
                .page_up => scroll -= @intCast(grid.rows),
                .arrow_down => scroll += 1,
                .arrow_up => scroll -= 1,
                .home => scroll = -@as(isize, @intCast(lines.items.len)),
                .end => scroll = @intCast(lines.items.len),
                else => {},
            },
            else => {},
        };
        if (dirty) {
            var next_built = buildEditorFrame(allocator, EditorHost.fromHost(&host), first_line, lines.items, scratch, ops, &tokens, colors, view, inner, cell_w, cell_h, grid, smoke_editor_bg, 0, 0, 0, null, sel_range, sel_scratch) catch built;
            if (next_built.cells.items.ptr != built.cells.items.ptr) {
                built.deinit(allocator);
                built = next_built;
            } else next_built = undefined;
        }
        if (scroll != 0) {
            // 상한은 **방금 그린 프레임이 준 값**이다(위 doc). 매 프레임 다시 세지 않는다.
            const next = if (scroll > 0)
                @min(first_line + @as(usize, @intCast(scroll)), built.written.max_top_line)
            else
                first_line -| @as(usize, @intCast(-scroll));
            if (next != first_line) {
                first_line = next;
                const next_built = try buildEditorFrame(allocator, EditorHost.fromHost(&host), first_line, lines.items, scratch, ops, &tokens, colors, view, inner, cell_w, cell_h, grid, smoke_editor_bg, 0, 0, 0, null, null, sel_scratch);
                built.deinit(allocator);
                built = next_built;
            }
        }
        // **caret 을 글리프 위에 얹는다.** 선택 띠는 렌더가 이미 그렸다(`selection_marks` → op) —
        // caret 만 플랫폼 몫이다(중립 `editor_view` 에 caret op 이 없다. macOS 도 quad 로 그린다).
        if (caret_at) |c| {
            var with_caret: std.ArrayList(d3d11_cells.Cell) = .empty;
            defer with_caret.deinit(allocator);
            try with_caret.ensureTotalCapacity(allocator, built.cells.items.len + 1);
            with_caret.appendSliceAssumeCapacity(built.cells.items);
            // 열은 **중립이 센다**(`content.columnOfByte`) — 렌더가 탭·§3.8 표기를 펴는 그 함수다.
            const layout = editor_view.geometry.compute(side_cols, lines.items.len, .{});
            const col = layout.contentLeft() + editor_view.content.columnOfByte(
                lines.items[c.line],
                4,
                c.byte_in_line,
                count_scratch,
            );
            with_caret.appendAssumeCapacity(d3d11_cells.solidCell(
                @floatFromInt(@as(u32, col) * cell_w),
                @floatFromInt(c.row * cell_h),
                2, // 2px 막대
                @floatFromInt(cell_h),
                d3d11_cells.colorFromArgb(0xFFFFFFFF),
                .{ 0, 0, 0, 0 },
            ));
            try host.drawFrame(with_caret.items, clear_argb);
        } else {
            try host.drawFrame(built.cells.items, clear_argb);
        }
    }

    const r = try judge(allocator, built.frame, lines.items, first_line, built.written.visual_rows);
    const stats = maru.renderer.renderFrameStats(built.frame, host.renderer_state.atlas.entryCount());
    try stdout.writeAll("maru.win32-editor-draw-smoke.v1\n");
    try stdout.print("doc={s} lines={d}\n", .{ doc_path, lines.items.len });
    try stdout.print("cell_px={d}x{d} grid={d}x{d}\n", .{ cell_w, cell_h, grid.cols, grid.rows });
    try stdout.print("ops={d} ops_text={d} ops_fill={d} ops_dropped={d}\n", .{ built.written.ops, built.ops_text, built.ops_fill, built.ops_dropped });
    try stdout.print("visual_rows={d} total_visual_rows={d}\n", .{ built.written.visual_rows, built.written.total_visual_rows });
    // **분모가 `script_judged` 다.** `script_steps` 로 내면 "잴 것이 없었다" 가 "틀렸다" 로 보인다.
    try stdout.print("sel_bands={d}/{d} first_cols={d} last_cols={d} match={}\n", .{ sel_rows_drawn, sel_rows_want, sel_first_cols, sel_last_cols, sel_rows_match });
    try stdout.print("click_glyphs={d}/{d} wide={d}\n", .{ click_matched, click_checked, click_wide });
    try stdout.print("scroll_script={d}/{d} steps={d} clamp_top={} clamp_bottom={}\n", .{ script_ok, script_judged, script_steps, clamp_top_ok, clamp_bottom_ok });
    try stdout.print("first_line={d} wheel_events={d} click_events={d} drag_moves={d} caret_line={?} sel={?}\n", .{
        first_line,                         wheel_events,                             click_events, drag_moves,
        if (caret_at) |c| c.line else null, if (sel_range) |s| s.hi - s.lo else null,
    });
    try stdout.print("d3d_cells={d} cells_digest=0x{X:0>16}\n", .{ built.cells.items.len, d3d11_cells.cellsDigest(built.cells.items) });
    try stdout.print("frames_presented={d}\n", .{frames});
    try stdout.print("lines_matched={d}/{d}\n", .{ r.matched, r.checked });
    try maru.renderer.writeRenderFrameStats(stdout, "renderer_", stats);
    try stdout.flush();
}

/// chrome 역할 하나를 D3D11 셀 색으로. **불투명하게 만든다** — chrome 토큰은 알파를 안 싣고,
/// 배경 면은 알파 0 이면 아무것도 안 그려진다(셰이더가 `bg.a` 로 판정한다).
fn cellColor(tk: *const maru.chrome.Tokens, role: maru.chrome.tokens.ColorRole) [4]f32 {
    const c = tk.get(role);
    return d3d11_cells.colorFromArgb(0xFF000000 |
        (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b));
}

/// 크롬 표면들이 쓰는 색 표 — **테마에서 온다**(`maru.chrome_theme.tokensFor`).
///
/// 전에는 여기 색 리터럴 열두 개가 박혀 있었다. 그래서 화면에서 **터미널만 테마를 따르고** 크롬은
/// 안 따랐다(실측: 터미널 `#101010` vs 도크 `#181D28` — §2m.33 의 인지된 부채). 이제 macOS 와
/// **같은 함수**를 지난다.
fn chromeTokensFor(cfg: anytype) maru.chrome.Tokens {
    const appearance = maru.config.appearance.resolve(cfg) catch
        return maru.chrome.Tokens.rich(std.mem.zeroes(maru.chrome.tokens.ThemeColors));
    return maru.chrome_theme.tokensFor(appearance);
}

/// `maru win32-scm-draw-smoke` — W8.4⒝⒞. **소스 컨트롤 표면이 Windows 화면에 뜨고 눌린다.**
///
/// §2m.6(파일 트리)·§2m.21(편집기)이 세운 모양 그대로다: fixture 를 안 만들고 **저장소 자신**의 git
/// 상태를 읽어 그 행을 그린다.
///
/// **컴포넌트 경로로 간다.** 처음엔 `coretext_frame_builder.buildDockScmDrawList`(셀 그리드)로 지었는데
/// 그것은 **P1b 가 걷어낸 경로**다 — 형제 히트테스트(`scmRowAt`)는 이미 지웠고(`app_session/git.zig`
/// 머리말) 그리기 함수만 고아로 남아 있었다. 계획 문서(`docs/plans/scm-dock.md` P1)가 *"셀 그리드
/// 경로를 제거한다. 히트테스트는 `chrome.ui.interaction` 이 소유한다"* 고 적어 둔 것을 안 보고 쓴
/// 실수였다. 지금은 macOS 제품과 **같은 함수**를 부른다: `build.build` → `view.view`.
fn runWin32ScmDrawSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-scm-draw-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const component = maru.chrome.components.scm_dock;

    var loaded = try maru.config.loader.loadDefault(io, allocator);
    defer loaded.deinit();
    const cfg = loaded.config;

    var host = draw_host.Host.open(allocator, cfg, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W8.4 source control)"),
    }) catch {
        try draw_host.reportSetupFailure(stderr, "win32-scm-draw-smoke");
        return error.UnknownCommand;
    };
    defer host.close();
    const cell_w = host.cell_w;
    const cell_h = host.cell_h;
    const grid = host.grid();

    // ── 제품 진입점으로 git 을 부른다 ─────────────────────────────────────────────────────────
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_native = root_buf[0..try std.Io.Dir.cwd().realPath(io, &root_buf)];
    const repo = try maru.path_shape.normalizeSeparators(allocator, root_native);
    defer allocator.free(repo);

    var backend = try git_backend_mod.Backend.init(io);
    defer backend.deinit();
    if (!backend.submitRepoStatus("git", repo, 1)) {
        try stderr.writeAll("maru win32-scm-draw-smoke: could not submit the repo status request\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    var rounds: usize = 0;
    var got: ?git_backend_mod.RepoStatusResult = null;
    while (rounds < 6000) : (rounds += 1) {
        if (backend.takeRepoStatusResult()) |t| {
            got = t;
            break;
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    var status = got orelse {
        try stderr.writeAll("maru win32-scm-draw-smoke: the repo status did not finish in time\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    // **`worker_allocator` 로 해제한다** — 결과는 백그라운드 스레드가 그 할당기로 만든다(§2m.9 실측).
    defer status.deinit(git_backend_mod.worker_allocator);
    if (!status.ok) {
        try stderr.writeAll("maru win32-scm-draw-smoke: git status failed\n");
        try stderr.flush();
        return error.UnknownCommand;
    }

    // ── 상태 → 화면. **이제 다시 그릴 수 있다** ─────────────────────────────────────────────
    //
    // 조립 전체를 `win32_scm_surface` 가 소유한다(§2m.29). 여기까지의 스모크는 프레임을 한 번 만들어
    // 120 번 표현했는데, 눌러서 무언가 바뀌려면 그 조립이 **상태의 함수**여야 한다.
    const tokens = maru.chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 },
        .sidebar_background = .{ .r = 0x18, .g = 0x1D, .b = 0x28 },
        .sidebar_foreground = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 },
        .sidebar_active = .{ .r = 0x2A, .g = 0x33, .b = 0x44 },
        .search_match = .{ .r = 20, .g = 120, .b = 255 },
        .search_match_current = .{ .r = 255, .g = 180, .b = 20 },
        .selection = .{ .r = 0x3A, .g = 0x5F, .b = 0xCD },
        .cursor = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF },
        .terminal_background = .{ .r = 0x1E, .g = 0x24, .b = 0x30 },
        .accent = .{ .r = 0xDD, .g = 0xA1, .b = 0x5E },
    });
    const opts = scm_surface.Options{
        .status_text = status.text,
        .font_family = cfg.font.family,
        .font_fallback = cfg.font.fallback,
        .font_size_pt = cfg.font.size,
        .tokens = &tokens,
    };

    var state = scm_surface.State{};
    var built = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch |err| {
        try stderr.print("maru win32-scm-draw-smoke: build failed({s})\n", .{@errorName(err)});
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer built.deinit();
    var rebuilds: usize = 0;

    // ── 판정 ⒜: 그려진 글자가 모델이 말한 것인가 ──────────────────────────────────────────────
    var names_checked: usize = 0;
    var names_matched: usize = 0;
    var branch_ok = false;
    if (built.model.head.branch) |br| {
        if (br.len > 0) branch_ok = std.mem.indexOf(u8, built.text, br) != null;
    }
    for (built.model.rows) |r| {
        const path = switch (r) {
            .file => |f| f.path,
            else => continue,
        };
        names_checked += 1;
        // **파일 이름으로 본다.** 컴포넌트는 경로를 한 덩어리로 안 그린다 — 파일명(굵게) + 디렉터리
        // (흐리게)로 나눈다(`scm_items.itemFor` 가 그 분할의 단일 출처다).
        if (std.mem.indexOf(u8, built.text, std.fs.path.basename(path)) != null) names_matched += 1;
    }

    // ── 판정 ⒝: 누른 자리가 그 행을 가리키는가 ───────────────────────────────────────────────
    var hits_checked: usize = 0;
    var hits_matched: usize = 0;
    for (built.items, 0..) |item, i| {
        const file = switch (item) {
            .file => |f| f,
            else => continue,
        };
        const slot = built.frame.tree.find(component.build.NodeIds.item(i)) orelse continue;
        const rect = built.frame.tree.entries[slot].rect;
        if (rect.width <= 0 or rect.height <= 0) continue;
        hits_checked += 1;
        const intent = scm_surface.click(&built, &state, rect.x + rect.width / 2, rect.y + rect.height / 2) orelse continue;
        switch (intent) {
            .open_row => |ref| if (ref.model_index == file.model_index) {
                hits_matched += 1;
            },
            else => {},
        }
    }
    // 위 순회가 선택을 옮겨 놨다 — 아래 판정이 그 자취를 딛지 않게 처음 상태로 되돌린다.
    state = .{};

    // ── 판정 ⒞1: **눌러서 접힌다** (W8.4⒞) ──────────────────────────────────────────────────
    //
    // 사람 없이 잰다: 섹션 머리 줄 rect 의 한가운데를 `.up` 으로 찍고, 돌아온 intent 를 상태에
    // 적용한 뒤 **다시 지어** 파일 행이 실제로 사라지는지 본다. 행 수는 모델이 정하므로 이 판정은
    // 저장소 상태가 무엇이든 성립한다.
    //
    // **판정 불가와 실패를 가른다.** 변경이 하나도 없는 저장소에는 누를 머리 줄이 없어 전부 0 이
    // 나오는데, 그것을 `collapse_toggled=false` 로만 적으면 **고장난 것처럼 읽힌다**(실측: 깨끗한
    // 저장소에서 그랬다). 이 세션에서 같은 함정을 네 번 밟았다.
    var collapse_before: usize = 0;
    var collapse_after: usize = 0;
    var collapse_restored: usize = 0;
    var toggled = false;
    var judgeable = true;
    var skip_reason: []const u8 = "";
    {
        collapse_before = countFileItems(built.items);
        // 섹션 머리 줄을 찾는다 — 항목 목록에서 첫 `.section` 이다.
        var header_index: ?usize = null;
        for (built.items, 0..) |item, i| switch (item) {
            .section => {
                header_index = i;
                break;
            },
            else => {},
        };
        if (header_index == null) {
            judgeable = false;
            skip_reason = "no_section_header";
        }
        if (header_index) |hi| find_hit: {
            const slot = built.frame.tree.find(component.build.NodeIds.item(hi)) orelse {
                judgeable = false;
                skip_reason = "header_not_in_tree";
                break :find_hit;
            };
            const rect = built.frame.tree.entries[slot].rect;
            const cx = rect.x + rect.width / 2;
            const cy = rect.y + rect.height / 2;
            const intent = scm_surface.click(&built, &state, cx, cy) orelse break :find_hit;
            if (intent != .toggle_section) break :find_hit;
            toggled = state.apply(intent);
            if (!toggled) break :find_hit;

            var next = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch break :find_hit;
            built.deinit();
            built = next;
            rebuilds += 1;
            collapse_after = countFileItems(built.items);

            // **다시 누르면 돌아온다.** 한 방향만 재면 "접힌 채로 굳는" 결함을 못 본다.
            const again = scm_surface.click(&built, &state, cx, cy) orelse break :find_hit;
            if (again != .toggle_section) break :find_hit;
            _ = state.apply(again);
            next = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch break :find_hit;
            built.deinit();
            built = next;
            rebuilds += 1;
            collapse_restored = countFileItems(built.items);
        }
    }

    // ── 판정 ⒞2: **행을 누르면 강조가 그 행으로 간다** ───────────────────────────────────────
    //
    // ⒝ 는 intent 가 그 행을 **이름 대는** 것까지만 봤다. 실제로 강조가 옮겨 가는지는 안 봤는데,
    // PR 은 그것을 주장하고 있었다(적대적 검증 3 회차). 셋을 다 본다: 상태가 바뀌었나, 다시 지은
    // 항목에 `selected` 가 섰나, **그림이 달라졌나**.
    var select_applied = false;
    var select_marked = false;
    var select_changed_picture = false;
    var select_judgeable = true;
    {
        var file_index: ?usize = null;
        for (built.items, 0..) |item, i| switch (item) {
            .file => {
                file_index = i;
                break;
            },
            else => {},
        };
        if (file_index == null) select_judgeable = false;
        if (file_index) |fi| sel: {
            const slot = built.frame.tree.find(component.build.NodeIds.item(fi)) orelse {
                select_judgeable = false;
                break :sel;
            };
            const rect = built.frame.tree.entries[slot].rect;
            const intent = scm_surface.click(&built, &state, rect.x + rect.width / 2, rect.y + rect.height / 2) orelse {
                select_judgeable = false;
                break :sel;
            };
            const ref = switch (intent) {
                .open_row => |r| r,
                else => {
                    select_judgeable = false;
                    break :sel;
                },
            };
            select_applied = state.apply(intent);
            const next = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch break :sel;
            built.deinit();
            built = next;
            rebuilds += 1;
            // **강조만 뺀 프레임과 비교한다.** 클릭 전후를 비교하면 호버도 함께 움직여 그 차이가
            // 강조 때문인지 알 수 없다 — 뮤턴트로 확인했다: 강조를 아예 안 세워도 `true` 였다.
            // 같은 interaction 상태에서 `selected` 만 지운 프레임을 지어 지문을 견준다.
            const with_selection = d3d11_cells.cellsDigest(built.cells);
            {
                var probe = state;
                probe.selected = null;
                if (scm_surface.build(allocator, host.surfaceCtx(), &probe, opts)) |*without| {
                    var w = without.*;
                    select_changed_picture = d3d11_cells.cellsDigest(w.cells) != with_selection;
                    w.deinit();
                    rebuilds += 1;
                } else |_| {
                    select_judgeable = false;
                }
            }
            // **모델 인덱스로 찾는다** — 화면 자리로 찾으면 이 판정이 `scm_items` 의 그 규율을 깬다.
            for (built.items) |item| switch (item) {
                .file => |f| if (f.model_index == ref.model_index) {
                    select_marked = f.selected;
                },
                else => {},
            };
        }
    }

    // ── 실제 창 — 사람이 눌러도 돈다 ─────────────────────────────────────────────────────────
    //
    // 위 판정은 좌표를 우리가 만들었다. 여기서는 **창이 준 좌표**로 같은 길을 돈다 — 마우스를
    // 올리면 hover 가, 누르면 접기·고르기가 일어나고 그때마다 다시 짓는다.
    //
    // **창이 준 좌표로도 한 번 잰다**(합성 메시지). 위 판정은 `pointer` 를 직접 불러서 창 →
    // `WindowEvent.mouse` → 위상 변환 세 칸을 안 밟는다 — 거기가 틀려도 초록이 된다.
    // **상태를 씻고 다시 짓는다.** 안 그러면 ⒞1 이 남긴 호버가 그대로라 "마우스를 올렸다" 가
    // 무변화로 읽힌다 — 실측으로 첫 이동이 `dirty=false` 였다.
    state = .{};
    if (scm_surface.build(allocator, host.surfaceCtx(), &state, opts)) |fresh| {
        built.deinit();
        built = fresh;
    } else |_| {}

    var frames: usize = 0;
    var clicks: usize = 0;
    var out_of_scope: usize = 0;
    const window_rows_before: usize = countFileItems(built.items);
    var window_rows_after: usize = window_rows_before;
    var window_intents: usize = 0;
    var hover_redraws: usize = 0;
    var hover_changed_picture: usize = 0;
    var press_redraws: usize = 0;
    var rebuild_ns_total: u64 = 0;
    var rebuild_ns_max: u64 = 0;
    const header_center: ?struct { x: i32, y: i32 } = blk: {
        for (built.items, 0..) |item, i| switch (item) {
            .section => {
                const slot = built.frame.tree.find(component.build.NodeIds.item(i)) orelse break :blk null;
                const rect = built.frame.tree.entries[slot].rect;
                break :blk .{ .x = @intFromFloat(rect.x + rect.width / 2), .y = @intFromFloat(rect.y + rect.height / 2) };
            },
            else => {},
        };
        break :blk null;
    };
    const row_action_center: ?struct { x: i32, y: i32 } = blk: {
        for (built.items, 0..) |item, i| switch (item) {
            .file => {
                const slot = built.frame.tree.find(component.build.NodeIds.itemAction(i)) orelse continue;
                const rect = built.frame.tree.entries[slot].rect;
                if (rect.width <= 0 or rect.height <= 0) continue;
                break :blk .{ .x = @intFromFloat(rect.x + rect.width / 2), .y = @intFromFloat(rect.y + rect.height / 2) };
            },
            else => {},
        };
        break :blk null;
    };
    while (frames < 240 and !host.quitting()) : (frames += 1) {
        // 창이 뜨고 몇 프레임 지난 뒤에 넣는다 — 첫 프레임엔 아직 `WM_SIZE` 등이 큐에 있다.
        //
        // **호버를 먼저 잰다.** 마우스를 올렸다 내리는 것만으로 화면이 다시 그려져야 한다 — 그
        // 자리가 빠져 있어서 마우스를 올려도 아무 표시가 안 났다(적대적 검증).
        if (frames == 5) if (header_center) |c| {
            host.window.postSyntheticMouse(.moved, c.x, c.y);
            host.window.postSyntheticMouse(.moved, c.x, 2); // 바깥으로 — 호버가 나가는 것도 그림이 바뀐다
        };
        // **범위 밖 intent 도 한 번 눌러 본다.** 안 누르면 `out_of_scope_intents=0` 이 "안 삼킨다"
        // 의 증거가 아니라 **한 번도 안 지난 자리**라는 뜻이 된다.
        if (frames == 20) if (row_action_center) |c| {
            host.window.postSyntheticMouse(.left_down, c.x, c.y);
            host.window.postSyntheticMouse(.left_up, c.x, c.y);
        };
        if (frames == 30) if (header_center) |c| {
            host.window.postSyntheticMouse(.left_down, c.x, c.y);
            host.window.postSyntheticMouse(.left_up, c.x, c.y);
        };
        for (try host.poll()) |ev| switch (ev) {
            .mouse => |m| {
                const phase: maru.chrome.ui.interaction.UiPointerPhase = switch (m.kind) {
                    .moved => .move,
                    .left_down => .down,
                    .left_up => .up,
                    else => continue,
                };
                if (phase == .up) clicks += 1;
                const routed = scm_surface.pointer(&built, &state, phase, @floatFromInt(m.x_px), @floatFromInt(m.y_px));
                var changed = routed.dirty;
                if (routed.intent) |intent| {
                    if (state.apply(intent)) {
                        changed = true;
                        window_intents += 1;
                    } else {
                        out_of_scope += 1;
                    }
                }
                // **호버만 바뀌어도 다시 그린다.** 안 그러면 마우스를 올려도 아무 표시가 안 난다 —
                // 상태는 바뀌는데 화면이 옛 프레임이다(적대적 검증에서 나온 결함).
                if (!changed) continue;
                // **호버와 누름을 가른다.** 한 통에 세면 "호버가 반응한다" 가 사실은 눌림 표시일
                // 수 있다(실측으로 그랬다 — 첫 판에 `.down` 이 호버로 세어졌다).
                const hover_only = routed.dirty and routed.intent == null and phase == .move;
                if (routed.dirty and phase == .down) press_redraws += 1;
                // **그림이 진짜 달라지는지 잰다.** 다시 그리기만 세면 "호버가 반응한다" 가 헛
                // 그리기여도 초록이 된다 — 컴포넌트가 그 노드에 호버 상태를 안 그릴 수도 있다.
                const before_digest = d3d11_cells.cellsDigest(built.cells);
                const t0 = std.Io.Clock.awake.now(io).nanoseconds;
                const next = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch continue;
                const dt: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0);
                rebuild_ns_total += dt;
                if (dt > rebuild_ns_max) rebuild_ns_max = dt;
                built.deinit();
                built = next;
                rebuilds += 1;
                window_rows_after = countFileItems(built.items);
                if (hover_only) {
                    hover_redraws += 1;
                    if (d3d11_cells.cellsDigest(built.cells) != before_digest) hover_changed_picture += 1;
                }
            },
            else => {},
        };
        try host.drawFrame(built.cells, 0xFF1E2430);
    }

    try stdout.writeAll("maru.win32-scm-draw-smoke.v3\n");
    try stdout.print("repo={s}\n", .{repo});
    try stdout.print("cell_px={d}x{d} grid={d}x{d}\n", .{ cell_w, cell_h, grid.cols, grid.rows });
    try stdout.print("branch={?s} ahead={d} behind={d}\n", .{ built.model.head.branch, built.model.head.ahead, built.model.head.behind });
    try stdout.print("model_rows={d} items={d} tree_entries={d} actions={d} empty={}\n", .{ built.model.rows.len, built.items.len, built.frame.tree.entries.len, built.frame.actions.len, built.model.empty });
    try stdout.print("ops={d} ops_text={d} ops_fill={d} ops_dropped={d}\n", .{ built.ops, built.ops_text, built.ops_fill, built.ops_dropped });
    try stdout.print("branch_drawn={} names_matched={d}/{d}\n", .{ branch_ok, names_matched, names_checked });
    try stdout.print("row_hits={d}/{d}\n", .{ hits_matched, hits_checked });
    if (judgeable) {
        try stdout.print("collapse_toggled={} file_rows={d}->{d}->{d}\n", .{ toggled, collapse_before, collapse_after, collapse_restored });
    } else {
        // **실패가 아니라 판정 불가다.** 이 저장소에는 누를 것이 없다.
        try stdout.print("collapse_toggled=unjudgeable reason={s}\n", .{skip_reason});
    }
    if (select_judgeable) {
        try stdout.print("select_applied={} select_marked={} select_changed_picture={}\n", .{ select_applied, select_marked, select_changed_picture });
    } else {
        try stdout.print("select=unjudgeable reason=no_file_row\n", .{});
    }
    try stdout.print("rebuilds={d} clicks={d} out_of_scope_intents={d}\n", .{ rebuilds, clicks, out_of_scope });
    try stdout.print("window_intents={d} window_file_rows={d}->{d} hover_redraws={d}/{d} press_redraws={d}\n", .{ window_intents, window_rows_before, window_rows_after, hover_changed_picture, hover_redraws, press_redraws });
    try stdout.print("rebuild_us_avg={d} rebuild_us_max={d}\n", .{ if (rebuilds > 2) rebuild_ns_total / (rebuilds - 2) / 1000 else 0, rebuild_ns_max / 1000 });
    try stdout.print("d3d_cells={d} cells_digest=0x{X:0>16} atlas_region_uploads={d}\n", .{ built.cells.len, d3d11_cells.cellsDigest(built.cells), built.atlas_region_uploads });
    try stdout.print("frames_presented={d}\n", .{frames});
    try maru.renderer.writeRenderFrameStats(stdout, "renderer_", built.stats);
    try stdout.flush();
}

/// 항목 목록의 **파일 행 수**. 접기 판정이 이 값으로 갈린다 — 섹션 머리 줄과 안내 줄은 접어도 남는다.
fn countFileItems(items: []const maru.chrome.components.scm_dock.types.Item) usize {
    var n: usize = 0;
    for (items) |item| switch (item) {
        .file => n += 1,
        else => {},
    };
    return n;
}

/// `maru win32-scm-write-smoke` — W8.4⒞2. **스테이지·언스테이지가 진짜 git 을 움직인다.**
///
/// ## 사용자의 작업트리를 절대 안 건드린다
///
/// 이것이 이 명령이 `win32-scm-draw-smoke` 와 갈린 **유일한 이유**다. 그리기 스모크는 저장소
/// 자신의 상태를 읽기만 하므로 cwd 에서 돌아도 되지만, 쓰기는 `git add` 를 실제로 실행한다 —
/// 사용자의 index 를 바꾸는 것은 스모크가 할 일이 아니다. 그래서 **자기 임시 저장소를 짓고**
/// 거기서만 쓴다(`<캐시>/scm-write-smoke/`, `user_paths.cacheBaseFor` 가 정한 자리).
///
/// ## 두 저장소를 본다
///
/// **unborn(첫 커밋 전) 저장소가 판정의 절반이다.** 거기서는 `HEAD` 가 없어 `restore --staged`
/// 가 못 돌고 `rm --cached` 여야 한다 — `git_write_command.kindForRow` 의 그 특례가 실제로
/// 필요한 유일한 자리이고, 보통 저장소만 재면 **그 분기가 한 번도 안 밟힌다.**
fn runWin32ScmWriteSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-scm-write-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const component = maru.chrome.components.scm_dock;

    var loaded = try maru.config.loader.loadDefault(io, allocator);
    defer loaded.deinit();
    const cfg = loaded.config;

    // **Windows 에서 `locate` 는 `null` 이다**(그 함수 doc) — `CreateProcessW` 가 `PATH` 를 스스로
    // 찾으므로 이름 그대로 넘긴다. 다른 스모크도 같다.
    var git_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_exe = git_backend_mod.locate(&git_exe_buf) orelse "git";

    var host = draw_host.Host.open(allocator, cfg, .{
        .title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W8.4 source control write)"),
    }) catch {
        try draw_host.reportSetupFailure(stderr, "win32-scm-write-smoke");
        return error.UnknownCommand;
    };
    defer host.close();

    const tokens = chromeTokensFor(cfg);
    try stdout.writeAll("maru.win32-scm-write-smoke.v1\n");
    try stdout.print("git={s}\n", .{git_exe});

    var total_fail: usize = 0;
    for ([_]bool{ false, true }) |unborn| {
        const repo = try makeScratchRepo(io, allocator, git_exe, unborn);
        defer allocator.free(repo);
        total_fail += try runScmWriteCase(io, allocator, stdout, stderr, &host, cfg, &tokens, git_exe, repo, unborn, component);
    }
    try stdout.print("cases_failed={d}\n", .{total_fail});
    try stdout.flush();
    if (total_fail != 0) return error.UnknownCommand;
}

/// 한 저장소에 대해 스테이지 → 언스테이지를 돌리고 판정한다. **실패 수**를 준다.
fn runScmWriteCase(
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    host: *draw_host.Host,
    cfg: anytype,
    tokens: *const maru.chrome.Tokens,
    git_exe: []const u8,
    repo: []const u8,
    unborn: bool,
    comptime component: type,
) !usize {
    const label = if (unborn) "unborn" else "normal";
    var status = try readRepoStatus(io, allocator, repo);
    defer allocator.free(status);

    var state = scm_surface.State{};
    var opts = scm_surface.Options{
        .status_text = status,
        .font_family = cfg.font.family,
        .font_fallback = cfg.font.fallback,
        .font_size_pt = cfg.font.size,
        .tokens = tokens,
    };
    var built = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch {
        try stderr.print("maru win32-scm-write-smoke[{s}]: build failed\n", .{label});
        return 1;
    };
    defer built.deinit();

    const staged_before = countRowsIn(built.model, .staged);
    const changes_before = countRowsIn(built.model, .changes);
    try host.drawFrame(built.cells, 0xFF1E2430);

    // ── ⑴ 행의 `+` 를 눌러 **스테이지** ──────────────────────────────────────────────────────
    var stage_ran = false;
    var stage_kind: []const u8 = "-";
    {
        const hit = actionCenterFor(&built, .changes, component) orelse {
            try stdout.print("[{s}] stage=unjudgeable reason=no_changes_row\n", .{label});
            return 1;
        };
        host.window.postSyntheticMouse(.left_down, hit.x, hit.y);
        host.window.postSyntheticMouse(.left_up, hit.x, hit.y);
        const intent = pumpForIntent(host, &built, &state) orelse {
            try stdout.print("[{s}] stage=unjudgeable reason=no_intent\n", .{label});
            return 1;
        };
        const write = scm_surface.writeFor(&built, intent) orelse {
            try stdout.print("[{s}] stage=unjudgeable reason=no_write intent={s}\n", .{ label, @tagName(intent) });
            return 1;
        };
        stage_kind = @tagName(write.kind);
        stage_ran = try applyWrite(allocator, git_exe, repo, write, stderr, label);
        if (!stage_ran) return 1;
        allocator.free(status);
        status = try readRepoStatus(io, allocator, repo);
        opts.status_text = status;
        // **목록이 통째로 바뀌었다** — 포인터 상태를 버린다(§2m.29 가 남긴 위험).
        state.invalidateTree();
        const next = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch return 1;
        built.deinit();
        built = next;
        try host.drawFrame(built.cells, 0xFF1E2430);
    }
    const staged_mid = countRowsIn(built.model, .staged);
    const changes_mid = countRowsIn(built.model, .changes);

    // ── ⑵ 스테이지된 행의 `−` 를 눌러 **언스테이지** ─────────────────────────────────────────
    var unstage_kind: []const u8 = "-";
    {
        const hit = actionCenterFor(&built, .staged, component) orelse {
            try stdout.print("[{s}] unstage=unjudgeable reason=no_staged_row\n", .{label});
            return 1;
        };
        host.window.postSyntheticMouse(.left_down, hit.x, hit.y);
        host.window.postSyntheticMouse(.left_up, hit.x, hit.y);
        const intent = pumpForIntent(host, &built, &state) orelse {
            try stdout.print("[{s}] unstage=unjudgeable reason=no_intent\n", .{label});
            return 1;
        };
        const write = scm_surface.writeFor(&built, intent) orelse {
            try stdout.print("[{s}] unstage=unjudgeable reason=no_write\n", .{label});
            return 1;
        };
        unstage_kind = @tagName(write.kind);
        if (!try applyWrite(allocator, git_exe, repo, write, stderr, label)) return 1;
        allocator.free(status);
        status = try readRepoStatus(io, allocator, repo);
        opts.status_text = status;
        state.invalidateTree();
        const next = scm_surface.build(allocator, host.surfaceCtx(), &state, opts) catch return 1;
        built.deinit();
        built = next;
        try host.drawFrame(built.cells, 0xFF1E2430);
    }
    const staged_after = countRowsIn(built.model, .staged);
    const changes_after = countRowsIn(built.model, .changes);

    // ── 판정 ─────────────────────────────────────────────────────────────────────────────────
    //
    // **화면 숫자가 아니라 git 이 바뀌었는지를 본다** — 모델은 매번 `git status` 원문에서 다시
    // 서므로, 아래 수치는 저장소의 진짜 상태다.
    const staged_ok = staged_mid == staged_before + 1 and changes_mid == changes_before - 1;
    const restored_ok = staged_after == staged_before and changes_after == changes_before;
    try stdout.print(
        "[{s}] stage_kind={s} unstage_kind={s} staged={d}->{d}->{d} changes={d}->{d}->{d} staged_ok={} restored_ok={}\n",
        .{ label, stage_kind, unstage_kind, staged_before, staged_mid, staged_after, changes_before, changes_mid, changes_after, staged_ok, restored_ok },
    );
    return @intFromBool(!(staged_ok and restored_ok));
}

/// 쓰기 하나를 **동기로** 돌린다. 스모크는 프레임을 기다릴 이유가 없으므로 백그라운드 슬롯을 안 쓴다
/// (`runWriteSync` 는 제품이 쓰는 것과 같은 조립·환경을 지난다 — Windows 갈래는 §2m.9 의 캡처 러너).
fn applyWrite(
    allocator: std.mem.Allocator,
    git_exe: []const u8,
    repo: []const u8,
    write: scm_surface.Write,
    stderr: *std.Io.Writer,
    label: []const u8,
) !bool {
    var one: [1][]const u8 = undefined;
    const paths: []const []const u8 = if (write.path) |p| blk: {
        one[0] = p;
        break :blk one[0..1];
    } else &.{};
    const out = git_backend_mod.runWriteSync(allocator, write.kind, git_exe, repo, paths, null) catch |err| {
        try stderr.print("maru win32-scm-write-smoke[{s}]: {s} failed({s})\n", .{ label, @tagName(write.kind), @errorName(err) });
        return false;
    };
    defer out.deinit(allocator);
    if (!out.ok()) {
        try stderr.print("maru win32-scm-write-smoke[{s}]: {s} exit={d} stderr={s}\n", .{ label, @tagName(write.kind), out.exit_code, out.stderr_bytes });
        return false;
    }
    return true;
}

/// 창 큐를 몇 번 돌려 **intent 하나**를 얻는다. 합성 메시지는 큐에 있으므로 곧 나온다.
fn pumpForIntent(host: *draw_host.Host, built: *const scm_surface.Built, state: *scm_surface.State) ?maru.chrome.components.scm_dock.ids.Intent {
    var spins: usize = 0;
    while (spins < 32) : (spins += 1) {
        const events = host.poll() catch return null;
        for (events) |ev| switch (ev) {
            .mouse => |m| {
                const phase: maru.chrome.ui.interaction.UiPointerPhase = switch (m.kind) {
                    .moved => .move,
                    .left_down => .down,
                    .left_up => .up,
                    else => continue,
                };
                if (scm_surface.pointer(built, state, phase, @floatFromInt(m.x_px), @floatFromInt(m.y_px)).intent) |intent| return intent;
            },
            else => {},
        };
    }
    return null;
}

/// 그 섹션의 **첫 파일 행의 동작 버튼**(`+`/`−`) 한가운데.
fn actionCenterFor(
    built: *const scm_surface.Built,
    section: maru.session.scm_view.Section,
    comptime component: type,
) ?struct { x: i32, y: i32 } {
    for (built.model.rows, 0..) |row, i| {
        const file = switch (row) {
            .file => |f| f,
            else => continue,
        };
        if (file.section != section) continue;
        const slot = built.frame.tree.find(component.build.NodeIds.itemAction(i)) orelse continue;
        const rect = built.frame.tree.entries[slot].rect;
        if (rect.width <= 0 or rect.height <= 0) continue;
        return .{ .x = @intFromFloat(rect.x + rect.width / 2), .y = @intFromFloat(rect.y + rect.height / 2) };
    }
    return null;
}

fn countRowsIn(model: maru.session.scm_view.Model, section: maru.session.scm_view.Section) usize {
    var n: usize = 0;
    for (model.rows) |row| switch (row) {
        .file => |f| if (f.section == section) {
            n += 1;
        },
        else => {},
    };
    return n;
}

/// 제품 진입점으로 `git status` 를 읽는다(`win32-scm-draw-smoke` 와 같은 길). 원문을 **복사해** 준다 —
/// 백엔드 결과는 워커 할당기 소유라 수명이 다르다.
fn readRepoStatus(io: std.Io, allocator: std.mem.Allocator, repo: []const u8) ![]u8 {
    var backend = try git_backend_mod.Backend.init(io);
    defer backend.deinit();
    if (!backend.submitRepoStatus("git", repo, 1)) return error.UnknownCommand;
    var rounds: usize = 0;
    while (rounds < 6000) : (rounds += 1) {
        if (backend.takeRepoStatusResult()) |taken| {
            var result = taken;
            defer result.deinit(git_backend_mod.worker_allocator);
            if (!result.ok) return error.UnknownCommand;
            return allocator.dupe(u8, result.text);
        }
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    return error.UnknownCommand;
}

/// 임시 저장소를 짓는다. **매번 처음부터** — 남은 상태가 판정을 흐리면 안 된다.
///
/// `unborn` 이면 커밋을 안 만든다: 그 저장소에서는 `HEAD` 가 없어 언스테이지가 `rm --cached` 로
/// 가야 하고, 그 분기는 여기서만 밟힌다.
fn makeScratchRepo(io: std.Io, allocator: std.mem.Allocator, git_exe: []const u8, unborn: bool) ![]u8 {
    // **`%LOCALAPPDATA%\maru\` 아래다**(user_paths §5.3) — 우리가 소유한 자리라 지웠다 다시 만들어도
    // 남의 것을 건드리지 않는다. 구분자는 입구에서 정규화한다(계약 §5 규칙 1).
    const xdg = maru.os_env.allocValue(allocator, "XDG_CACHE_HOME");
    defer if (xdg) |v| allocator.free(v);
    const lad = maru.os_env.allocValue(allocator, "LOCALAPPDATA");
    defer if (lad) |v| allocator.free(v);
    const base = maru.user_paths.cacheBaseFor(@import("builtin").os.tag, xdg, lad) orelse return error.UnknownCommand;
    const native = try std.fmt.allocPrint(allocator, "{s}/maru/scm-write-smoke/{s}", .{ base, if (unborn) "unborn" else "normal" });
    defer allocator.free(native);
    const repo = try maru.path_shape.normalizeSeparators(allocator, native);
    errdefer allocator.free(repo);

    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, repo) catch {};
    // 부모부터 만든다 — `createDir` 은 한 단계씩이다(이미 있으면 넘어간다).
    var cut: usize = 0;
    while (std.mem.indexOfScalarPos(u8, repo, cut + 1, '/')) |slash| : (cut = slash) {
        cwd.createDir(io, repo[0..slash], .default_dir) catch {};
    }
    try cwd.createDir(io, repo, .default_dir);

    try runSetup(allocator, git_exe, repo, &.{ git_exe, "init", "-q" });
    try runSetup(allocator, git_exe, repo, &.{ git_exe, "config", "user.email", "smoke@maru.test" });
    try runSetup(allocator, git_exe, repo, &.{ git_exe, "config", "user.name", "maru smoke" });

    // 파일 셋. 보통 저장소는 커밋해 두고 다시 고쳐 **변경 사항** 셋을 만든다.
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| try writeScratchFile(io, repo, name, "base\n");
    if (!unborn) {
        try runSetup(allocator, git_exe, repo, &.{ git_exe, "add", "-A" });
        try runSetup(allocator, git_exe, repo, &.{ git_exe, "commit", "-q", "-m", "base" });
        for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| try writeScratchFile(io, repo, name, "changed\n");
    }
    return repo;
}

fn writeScratchFile(io: std.Io, repo: []const u8, name: []const u8, body: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ repo, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

fn runSetup(allocator: std.mem.Allocator, git_exe: []const u8, repo: []const u8, argv: []const []const u8) !void {
    _ = git_exe;
    var out = try maru.win32_process.capture(allocator, argv, repo, .stdout_only, &.{}, &.{}, 64 * 1024);
    defer out.deinit(allocator);
    if (out.exit_code != 0) return error.UnknownCommand;
}
