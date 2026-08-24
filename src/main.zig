const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
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

// **그 파일의 테스트를 실제로 돌린다.** 위 import 는 `runWin32ScmDrawSmoke` 안에서만 쓰이는데,
// 테스트 아티팩트는 `main` 을 안 부르므로 그 함수가 분석되지 않아 **테스트가 한 줄도 안 돌았다**
// (실측: 추가 직후 `zig build test` 출력에 `win32_scm_surface` 가 0 회). 이 저장소가 §2m.18 에서
// 같은 것을 밟았다.
test {
    _ = scm_surface;
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
        try runSsh(allocator, &args, stderr);
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
    maru.session.core_command.apply(core, .{
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

const smoke_spin_cap: usize = 600;

test "합성 기하: 창이 좁으면 도크가 사라지고, 있을 때는 겹치지 않는다" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const cell_w: u32 = 9;
    const cell_h: u32 = 19;
    var saw_dock = false;
    var saw_no_dock = false;
    var w: u32 = 40;
    while (w <= 1600) : (w += 37) {
        const g = dockGeometryFor(w, 640, cell_w, cell_h, true, 0, .explorer, 0, 0);
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
    /// **실제로 그린 행 수.** 히트테스트가 이 값을 써야 한다 — `rows.len` 을 쓰면 안 그린 행이
    /// 눌린다(실측: 110 행짜리 디렉터리에서 도크 맨 아래를 누르면 그리지 않은 29 행이 나왔다).
    drawn: *u16,
) !?maru.renderer.RenderFrame {
    drawn.* = 0;
    const area = geom.tree_content;
    if (area.w < cell_w or area.h < cell_h) return null;
    const cols: u16 = @intCast(area.w / cell_w);
    const rows_visible: u16 = @intCast(@min(rows.len, area.h / cell_h));
    drawn.* = rows_visible;
    if (cols == 0 or rows_visible == 0) return null;

    const fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 } };
    const active_fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    var list = try cell_text.buildFileTreeDrawList(
        allocator,
        rows,
        null,
        0,
        rows_visible,
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
    drawn: *u16,
    frame_slot: *?maru.renderer.RenderFrame,
    /// 지금 도크가 보이는 것. **뷰마다 다른 표면**을 그린다(W8.7c2).
    view: maru.session.dock_panel.View,
    tk: *const maru.chrome.Tokens,
    view_bar_frame: *?maru.renderer.RenderFrame,
    /// 소스 컨트롤 뷰가 쓰는 것들. `status` 가 비어 있으면 그 뷰는 아무것도 안 그린다.
    scm: ScmDockInputs,
) !void {
    try rebuildDockCells(allocator, out, geom, tk);
    if (view != .explorer) {
        if (frame_slot.*) |*old_frame| {
            old_frame.deinit(allocator);
            frame_slot.* = null;
        }
        drawn.* = 0;
        if (view == .source_control) try appendScmDockCells(allocator, out, geom, renderer_state, builder, cell_w, cell_h, pipeline, atlas_w, atlas_h, uploaded, scm);
        // **뷰 바는 내용 뒤에 굽는다.** 먼저 구우면 그 뒤 내용이 아틀라스를 키울 때 UV 가 낡아
        // **다른 글리프가 나온다**(실측: 폴더·git·code 자리에 git·폴더·git 이 떴다). §2m.32 가
        // "업로드 목록은 프레임과 함께 사라진다" 를 적었다면, 이것은 그 짝인 **UV 낡음**이다.
        appendViewBarCells(allocator, out, geom, cell_w, cell_h, view, tk, renderer_state, builder, pipeline, atlas_w, atlas_h, uploaded, view_bar_frame) catch {};
        return;
    }
    if (frame_slot.*) |*old| {
        old.deinit(allocator);
        frame_slot.* = null;
    }
    if (rows.len == 0) return;
    const built = (try buildDockTreeFrame(allocator, renderer_state, builder, rows, geom, cell_w, cell_h, drawn)) orelse return;
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
    const x0: f32 = @floatFromInt(geom.tree_content.x);
    const y0: f32 = @floatFromInt(geom.tree_content.y);
    const x1: f32 = @floatFromInt(geom.tree_content.x + geom.tree_content.w);
    const y1: f32 = @floatFromInt(geom.tree_content.y + geom.tree_content.h);
    for (native) |n| {
        const cell = win32_terminal.cellFromNative(n, cell_w, cell_h, atlas_w.*, atlas_h.*);
        // **트리 글자가 도크 사각형을 벗어나면 안 된다.** 여기서 원점을 안 찍으면 글자가 창 왼쪽
        // 위에서 시작해 **터미널 위에** 얹힌다 — 터미널 쪽과 달리 이 판정은 실제로 발동한다
        // (`tree_content.x` 가 0 이 아니다).
        if (cell.rect[0] < x0 or cell.rect[1] < y0 or
            cell.rect[0] + cell.rect[2] > x1 or cell.rect[1] + cell.rect[3] > y1) outside.* += 1;
        out.appendAssumeCapacity(cell);
    }
    // 위 주석과 같은 이유로 **내용 뒤에** 굽는다.
    appendViewBarCells(allocator, out, geom, cell_w, cell_h, view, tk, renderer_state, builder, pipeline, atlas_w, atlas_h, uploaded, view_bar_frame) catch {};
}

/// 상단 띠 전체 — 배경 + 캡션 버튼.
fn rebuildTitlebarCells(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(d3d11_cells.Cell),
    client_w: u32,
    titlebar_px: u32,
    btn_w: u32,
    hovered: ?usize,
    maximized: bool,
    tk: *const maru.chrome.Tokens,
) !void {
    out.clearRetainingCapacity();
    if (titlebar_px == 0) return;
    try out.append(allocator, d3d11_cells.solidCell(
        0,
        0,
        @floatFromInt(client_w),
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
    sidebar_w: u32,
    cell_w: u32,
    cell_h: u32,
    /// 카드에 실을 것들 — 지금 세션 하나. 슬라이스라 호출자가 수명을 안다.
    card: SidebarCard,
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
) !void {
    out.clearRetainingCapacity();
    glyphs.* = 0;
    outside.* = 0;
    if (sidebar_w == 0) return;
    // **띠 아래에서 시작한다.** 사이드바 헤더가 아직 없으므로(⒞) 띠는 캡션 버튼만 쓰고, 카드가
    // 그 위로 올라가면 글자가 잘린다(실측: 프레임리스로 바꾸자 이름줄이 띠에 먹혔다).
    const top_y = geom.workspace.y;
    const h = geom.workspace.h;
    try out.append(allocator, d3d11_cells.solidCell(
        0,
        @floatFromInt(top_y),
        @floatFromInt(sidebar_w),
        @floatFromInt(h),
        cellColor(tk, .surface_bg),
        .{ 0, 0, 0, 0 },
    ));

    // 카드 하나 — 지금 세션. **줄 수를 여기서 정하고 그 값으로 높이를 얻는다**(그 필드 doc: 호스트가
    // 렌더에 쓰는 줄 수와 같은 값을 실어야 클릭 좌표가 안 갈린다).
    const sb = maru.chrome.components.sidebar;
    const m = sb.Metrics.init(cell_h, cell_h);
    // **카드가 실제로 그리는 줄 수를 쓴다.** 1 로 박아 두면 밴드가 글자보다 짧아져 둘째 줄이 밖으로
    // 나간다(판정 `sidebar_cells_outside` 가 4 를 냈다 — 그 필드 doc 이 예고한 그대로다:
    // "host 가 렌더에 쓰는 줄 수와 같은 값을 실어야 한다").
    const lines: u8 = card.lines;
    const card_h = sb.cardHeight(lines, m);
    const top = top_y + m.content_pad_v;
    if (top + card_h > h) return;
    try out.append(allocator, d3d11_cells.solidCell(
        0,
        @floatFromInt(top),
        @floatFromInt(sidebar_w),
        @floatFromInt(card_h),
        cellColor(tk, .tab_active_bg),
        .{ 0, 0, 0, 0 },
    ));
    // 활성 카드의 **좌측 앰버 막대**(chrome-strategy.md U1) — 어느 세션이 활성인지의 신호다.
    try out.append(allocator, d3d11_cells.solidCell(
        0,
        @floatFromInt(top),
        3,
        @floatFromInt(card_h),
        cellColor(tk, .accent_bar),
        .{ 0, 0, 0, 0 },
    ));

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
    const indent_cols: u16 = @intCast((@as(u32, sp.card_gap_px) + @as(u32, sp.accent_bar_width_px) + cell_w - 1) / cell_w);
    const cols: u16 = @intCast(sidebar_w / cell_w);
    if (cols < indent_cols + 4) return;
    const fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xC8, .g = 0xD0, .b = 0xE0 } };
    const active_fg: maru.terminal.Color = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } };
    var names = [_][]const u8{card.name};
    var branches = [_][]const u8{card.branch};
    var paths = [_][]const u8{card.folder};
    const empty: []const []const u8 = &.{};
    const list = cell_text.buildSidebarDrawList(
        allocator,
        &names,
        &branches,
        &paths,
        empty,
        &.{},
        &.{},
        &.{},
        cols -| indent_cols,
        fg,
        &.{},
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
    const rows = [_]maru.chrome.components.sidebar.Row{.{ .card = .{ .tab = 0, .label = card.name, .active = true, .lines = @intCast(card.lines) } }};
    maru.sidebar_glyph_rows.fillOriginY(allocator, native, &rows, m);
    // `fillOriginY` 는 **content 상대**다(목록 위 여백부터). 띠만큼 통째로 내린다 — 밴드와 같은 기준.
    for (native) |*n| n.origin_y +|= top_y;
    try out.ensureUnusedCapacity(allocator, native.len);
    // **판정은 카드 밴드 기준이다.** 사이드바 사각형으로 재면 속 빈다 — 글자가 카드 밖으로 나가도
    // 띠 안이라 0 이 나온다(실측: 행 인코딩을 안 지운 뮤턴트가 그렇게 통과했다).
    const x1: f32 = @floatFromInt(sidebar_w);
    const band_y0: f32 = @floatFromInt(top);
    const band_y1: f32 = @floatFromInt(top + card_h);
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

/// 사이드바 카드 한 장이 싣는 것. 빈 문자열이면 그 줄을 안 그린다(`buildSidebarDrawList` 의 계약).
const SidebarCard = struct {
    name: []const u8,
    branch: []const u8 = "",
    folder: []const u8 = "",
    lines: u8 = 1,
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
    try out.ensureUnusedCapacity(allocator, native.len);
    for (native) |n| out.appendAssumeCapacity(win32_terminal.cellFromNative(n, cell_w, cell_h, atlas_w.*, atlas_h.*));
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
        .status_bar_px = 0,
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
    window.setFrameless(titlebar_px, caption_buttons_px);

    var client_w = initial.width_px;
    var client_h = initial.height_px;
    var geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px);

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

    var live: maru.app.LivePtySession = undefined;
    try live.init(io, allocator, 10, .{ .command = command, .args = args, .size = start }, 16);
    defer live.deinit();

    var surfaces = [_]maru.session.surface.Surface{try maru.session.surface.Surface.init(allocator, 1, start)};
    defer surfaces[0].deinit();
    surfaces[0].title = "win32 terminal";
    surfaces[0].command = command;

    // **앱 수준 config 를 코어에 한 번에 건다.** 스크롤백 길이·팔레트·기본 전경/배경·모호폭/이모지폭·
    // 커서 모양이 여기서 온다 — 예전에는 전부 코어 기본값이라 `scrollback.lines` 를 바꿔도 무동작이었다.
    //
    // **`set_runtime_config` 한 묶음으로 보낸다.** 값마다 명령을 따로 보내면 자식의 첫 출력이 그 사이에
    // 끼어 **옛 설정으로 파싱**되는 자리가 생긴다(macOS 가 같은 이유로 이 묶음을 쓴다). 리더가 뜨기 전에
    // 거는 것도 같은 이유다.
    //
    // **셀 크기도 함께 준다.** 코어가 링크 판정·마우스 좌표에 셀 크기를 쓰는데, 안 주면 기본값으로 굳어
    // 폰트를 키워도 그 계산만 옛 값을 본다.
    applyCoreConfig(&surfaces[0].core, cfg, appearance, cell_w, cell_h);

    var tab_ptrs = [_]*maru.session.surface.Surface{&surfaces[0]};
    var app_window: maru.session.window.AppWindow = .{ .tabs = &tab_ptrs };

    var runtime = maru.app.SurfaceRuntime.init(allocator);
    defer runtime.deinit();
    _ = try live.attachSurface(&runtime, &surfaces[0], true);

    var pump = live.pump(&runtime);
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
    scan: {
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_native = root_buf[0..(std.Io.Dir.cwd().realPath(io, &root_buf) catch break :scan)];
        const root_path = maru.path_shape.normalizeSeparators(allocator, root_native) catch break :scan;
        dock_root = root_path;
        dock_tree.replaceExplicitRoots(&.{root_path}) catch break :scan;

        var backend = file_tree_backend.Backend.init(allocator, io) catch break :scan;
        defer backend.deinit();
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
    var dock_region_uploads: usize = 0;
    var dock_cells_outside: usize = 0;
    var dock_rows_drawn: u16 = 0;
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
    const scm_tokens = chromeTokensFor(cfg);
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

    var sidebar_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer sidebar_cells.deinit(allocator);
    var sidebar_frame: ?maru.renderer.RenderFrame = null;
    defer if (sidebar_frame) |*f| f.deinit(allocator);
    var sidebar_uploads: usize = 0;
    var sidebar_glyphs: usize = 0;
    var sidebar_outside: usize = 0;
    const sidebar_card = SidebarCard{
        .name = surfaces[0].title,
        .branch = "",
        .folder = if (dock_root) |r| std.fs.path.basename(r) else "",
        .lines = if (dock_root != null) 2 else 1,
    };
    try rebuildTitlebarCells(allocator, &titlebar_cells, client_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens);
    try rebuildSidebarCells(allocator, &sidebar_cells, geom, sidebar_w, cell_w, cell_h, sidebar_card, &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame);

    var dock_cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer dock_cells.deinit(allocator);
    var dock_tree_frame: ?maru.renderer.RenderFrame = null;
    var view_bar_frame: ?maru.renderer.RenderFrame = null;
    defer if (view_bar_frame) |*f| f.deinit(allocator);
    defer if (dock_tree_frame) |*f| f.deinit(allocator);
    rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }) catch {};

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
    while ((max_spins == null or spins < max_spins.?) and !window.quit_requested and !close_requested) : (spins += 1) {
        if (spins == 60) {
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
        if (spins == 90 and geom.divider.w != 0) {
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
        if (spins == 150 and geom.view_bar.w != 0) {
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
        // 전환 뒤 **소스 컨트롤 행을 눌러 본다** — 뷰가 바뀌었는데 안 눌리면 죽은 컨트롤이다.
        if (spins == 200 and dock_view == .source_control) {
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
        if (spins == 250 and titlebar_px != 0) {
            caption_judgeable = true;
            caption_max_before = window.isMaximized();
            const r = captionButtonRects(client_w, titlebar_px, caption_btn_w)[1];
            const cx: i32 = @intCast(r.x + r.w / 2);
            const cy: i32 = @intCast(r.y + r.h / 2);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
        }
        if (spins == 330 and caption_judgeable) {
            caption_max_after = window.isMaximized();
            // **지금 폭으로 다시 잰다** — 최대화로 클라이언트가 넓어졌으므로 옛 사각형을 쓰면
            // 화면 한복판을 누르게 된다.
            const r = captionButtonRects(client_w, titlebar_px, caption_btn_w)[1];
            const cx: i32 = @intCast(r.x + r.w / 2);
            const cy: i32 = @intCast(r.y + r.h / 2);
            window.postSyntheticMouse(.left_down, cx, cy);
            window.postSyntheticMouse(.left_up, cx, cy);
        }
        if (spins == 410 and caption_judgeable) caption_max_restored = window.isMaximized();
        // ── 프레임리스 배선 판정 (W8.8⒝) ───────────────────────────────────────────────────
        //
        // 복원이 끝난 뒤 잰다 — 최대화 중에는 창 사각형이 화면 작업영역이라 값이 흔들린다.
        if (spins == 450 and titlebar_px != 0) {
            frameless_covers = window.clientCoversWindow();
            const wr = window.windowRect();
            const border: i32 = 8; // 모서리 규칙에 안 걸리게 충분히 안쪽에서 찌른다
            // 띠의 **빈 곳**(왼쪽) → 캡션, 캡션 **버튼 자리** → 클라이언트, 띠 **아래** → 클라이언트.
            const mid_x: i32 = wr.left + @divTrunc(@as(i32, @intCast(client_w)), 2);
            nchittest_strip = window.probeHitTest(mid_x, wr.top + border + 4);
            nchittest_button = window.probeHitTest(wr.right - 10, wr.top + border + 4);
            nchittest_below = window.probeHitTest(mid_x, wr.top + @as(i32, @intCast(titlebar_px)) + 20);
        }
        if (spins == 120) {
            selections_before_term_click = selections;
            dock_clicks_before_term_click = dock_row_clicks;
            const tx: i32 = @intCast(geom.terminal.x + geom.terminal.w / 2);
            const ty: i32 = @intCast(geom.terminal.y + geom.terminal.h / 2);
            window.postSyntheticMouse(.left_down, tx, ty);
            window.postSyntheticMouse(.left_up, tx, ty);
        }
        for (window.poll()) |ev| switch (ev) {
            .resized => |r| {
                try present.resize(r.width_px, r.height_px);
                // **기하를 먼저 다시 잰다** — 도크 폭이 창 크기에 따라 달라지므로 터미널 사각형도 바뀐다.
                client_w = r.width_px;
                client_h = r.height_px;
                geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px);
                // **터미널 격자도 바꾼다.** 스왑체인만 맞추면 셸이 옛 크기로 계속 출력해 줄이 어긋난다.
                if (win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h)) |size| {
                    loop.resizeActiveSurface(size) catch {};
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
                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }) catch {
                    dock_rebuild_failures += 1;
                };
                rebuildSidebarCells(allocator, &sidebar_cells, geom, sidebar_w, cell_w, cell_h, sidebar_card, &chrome_tokens, &renderer_state, builder, pipeline, &atlas_w, &atlas_h, &sidebar_uploads, &sidebar_glyphs, &sidebar_outside, &sidebar_frame) catch {};
                rebuildTitlebarCells(allocator, &titlebar_cells, client_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens) catch {};
            },
            .paint => {},
            .close_requested => close_requested = true,
            // **입력이 여기서 셸로 간다.** 창은 중립 `KeyEvent`만 주고, 앱 동작이냐 셸 입력이냐는
            // `handleKeyEvent`(중립 정책)가 정한다 — Windows 가 키바인딩을 다시 발명하지 않는다.
            .key => |key_ev| {
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
                // **띠 위는 영역 판정보다 먼저 본다.** `regionAt` 은 띠를 모르므로(작업영역 기준)
                // 여기서 안 가로채면 캡션 버튼 클릭이 터미널 선택이 된다.
                if (titlebar_px != 0 and m.y_px >= 0 and m.y_px < @as(i32, @intCast(titlebar_px))) {
                    const rects = captionButtonRects(client_w, titlebar_px, caption_btn_w);
                    var hit: ?usize = null;
                    for (rects, 0..) |r, i| {
                        if (m.x_px >= @as(i32, @intCast(r.x)) and m.x_px < @as(i32, @intCast(r.x + r.w))) hit = i;
                    }
                    if (hit != caption_hover) {
                        caption_hover = hit;
                        rebuildTitlebarCells(allocator, &titlebar_cells, client_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens) catch {};
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
                    rebuildTitlebarCells(allocator, &titlebar_cells, client_w, titlebar_px, caption_btn_w, caption_hover, window.isMaximized(), &chrome_tokens) catch {};
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
                            geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px);
                            // **화면에 선 크기를 도로 저장한다.** 포인터가 창 밖으로 나가면 `pt` 는
                            // 화면보다 훨씬 큰 값이 되는데(실측: `stored_pt=5979` 인데 `shown_w=654`),
                            // 그 상태로 창을 키우면 도크가 **새 공간을 통째로 먹는다**(실측: 654 →
                            // 1254px, 터미널이 35 열로 쪼그라들었다). macOS 가 같은 자리에서
                            // `sizePtForEffectiveWidth` 로 되쓰는 이유다.
                            dock_size_pt = maru.session.dock_layout.sizePtForEffectiveWidth(geom.dock_size_px, 0, 1000);
                            // **터미널 격자도 따라간다** — 창 크기가 바뀐 것과 같은 일이다.
                            if (win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h)) |size|
                                loop.resizeActiveSurface(size) catch {};
                            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }) catch {
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
                                    geom = dockGeometryFor(client_w, client_h, cell_w, cell_h, dock_visible, dock_size_pt, dock_view, sidebar_w, titlebar_px);
                                    if (win32_window.cellsForClient(geom.terminal.w, geom.terminal.h, cell_w, cell_h)) |size|
                                        loop.resizeActiveSurface(size) catch {};
                                    rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }) catch {
                                        dock_rebuild_failures += 1;
                                    };
                                };
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
                                rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }) catch {
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
                            if (maru.session.file_tree_layout.rowAtLocalY(cell_h, 0, local_y, dock_rows_drawn)) |row| {
                                dock_row_clicks += 1;
                                dock_last_row = row;
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
                        // 둘 다 위에서 이미 `continue` 했다.
                        .wheel, .capture_lost => unreachable,
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

        var tick = try loop.tickWithFrameBuilder(builder);
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
            rebuildDockAll(allocator, &dock_cells, geom, &renderer_state, builder, dock_rows.items, cell_w, cell_h, pipeline, &atlas_w, &atlas_h, &dock_region_uploads, &dock_cells_outside, &dock_rows_drawn, &dock_tree_frame, dock_view, &chrome_tokens, &view_bar_frame, .{ .status = scm_status, .state = &scm_state, .opts = scm_opts, .built = &scm_built }) catch {
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

        cells.clearRetainingCapacity();
        try cells.ensureTotalCapacity(allocator, native.len + dock_cells.items.len + sidebar_cells.items.len + titlebar_cells.items.len);
        // **사이드바·도크가 먼저다** — 그리는 순서가 z 순서이고, 터미널 글자가 그 배경에 덮이면 안 된다.
        cells.appendSliceAssumeCapacity(sidebar_cells.items);
        cells.appendSliceAssumeCapacity(dock_cells.items);
        const term_first = cells.items.len;
        for (native) |n| cells.appendAssumeCapacity(win32_terminal.cellFromNative(n, cell_w, cell_h, atlas_w, atlas_h));
        // **여기까지가 터미널이다.** 아래 침범 판정이 이 구간만 봐야 한다 — 띠를 함께 세면 띠가 창
        // 폭을 가로지르고 `y=0` 에서 시작하므로 **두 판정이 영원히 0 이 아니게 되어 죽는다**
        // (실측: 둘 다 15600 = 띠 26 셀 × 600 프레임).
        const term_last = cells.items.len;
        // **띠는 맨 위다** — 터미널·도크 위에 얹혀야 캡션 버튼이 안 가려진다.
        cells.appendSlice(allocator, titlebar_cells.items) catch {};
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
        try stdout.print("frameless_covers_window={} nchittest_strip={d} nchittest_button={d} nchittest_below={d} frameless_wiring_ok={}\n", .{
            frameless_covers,
            nchittest_strip,
            nchittest_button,
            nchittest_below,
            frameless_covers and nchittest_strip == 2 and nchittest_button == 1 and nchittest_below == 1,
        });
    }
    try stdout.print("sidebar_w={d} sidebar_cells={d} sidebar_glyphs={d} sidebar_cells_outside={d} term_x={d}\n", .{ sidebar_w, sidebar_cells.items.len, sidebar_glyphs, sidebar_outside, geom.terminal.x });
    try stdout.print("dock_scan_ok={} dock_rows={d} dock_region_uploads={d} dock_tree_frame={} dock_cells_outside={d} dock_rows_drawn={d}\n", .{ dock_scan_ok, dock_rows.items.len, dock_region_uploads, dock_tree_frame != null, dock_cells_outside, dock_rows_drawn });
    if (dock_click_judgeable) {
        // **동어반복을 피한다**: 누른 자리가 그 행이라는 것만 보면 내가 만든 좌표를 내가 되읽는
        // 것이다. 그 행의 **이름**을 모델에서 꺼내 함께 적어, 화면에 뜬 목록과 대조할 수 있게 한다.
        const name: []const u8 = if (dock_last_row) |r| blk: {
            if (r >= dock_rows.items.len) break :blk "<out-of-range>";
            break :blk switch (dock_rows.items[r]) {
                .root => |x| x.label,
                .directory => |x| x.label,
                .file, .recent_file => |x| x.label,
                .recent_header => "<recent-header>",
                .empty => "<empty>",
            };
        } else "<none>";
        try stdout.print("dock_pointer_events={d} dock_row_clicks={d} dock_last_row={?d} want_row={d} row_name={s}\n", .{ dock_pointer_events, dock_row_clicks, dock_last_row, dock_click_target_row, name });
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
        surfaces[0].core.screen.sb.cap,
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
                    session_host.restore_activation.run(
                        allocator,
                        io,
                        restore,
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
                const dir_z = try allocator.dupeZ(u8, daemon.session_dir);
                defer allocator.free(dir_z);
                const socket_z = try allocator.dupeZ(u8, daemon.socket_path);
                defer allocator.free(socket_z);
                session_host.daemon.runSessionHostWithIdentity(
                    allocator,
                    io,
                    dir_z,
                    socket_z,
                    daemon.host_id,
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
    /// `maru ssh` — `/bin/sh -c <래퍼 스크립트>`를 execve해 원격에 terminfo를 심고 ssh로 프로세스를 교체한다.
    /// Windows에는 `/bin/sh`가 없고 `environ` 심볼도 msvcrt에 없어 **링크가 깨진다**(실측:
    /// `lld-link: undefined symbol: environ`).
    ssh,
    /// `maru install-cli` — `~/.local/bin/maru`에 symlink를 건다. Windows에는 그 관례가 없고, symlink는 개발자
    /// 모드나 관리자 권한을 요구하며, `symlink` 심볼 자체가 msvcrt에 없다(실측: `undefined symbol: symlink`).
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
        .install_cli => "maru install-cli is not supported on Windows yet (docs/plans/windows-platform.md W10).",
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

fn runSsh(allocator: std.mem.Allocator, args: anytype, stderr: *std.Io.Writer) !void {
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

    const argv = try maru.cli.ssh.buildArgv(allocator, parsed, ctl);
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

    // 현재 환경을 상속해 `/bin/sh -c <script>`를 exec한다 — 성공하면 이 프로세스가 sh→ssh로 대체된다
    // (SSH_AUTH_SOCK 등 그대로 흐른다. TERM은 스크립트가 ssh `-o SetEnv`로 정한다). 돌아오면 실패다.
    _ = std.c.execve("/bin/sh", c_argv, @ptrCast(std.c.environ));
    try stderr.writeAll("maru ssh: failed to exec /bin/sh\n");
    try stderr.flush();
    return error.UnknownCommand;
}

fn runInstallCli(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    // Windows 미지원(백로그 W10) — 이유는 `HostGatedFeature.install_cli`. 설치 위치(`%LOCALAPPDATA%\Programs`?)·
    // shim 방식(symlink vs `.cmd`)·PATH 등록이 전부 계약에 없는 결정이라 별도 슬라이스로 나눴다.
    if (gate_install_cli) |reason| {
        try stderr.print("{s}\n", .{reason});
        try stderr.flush();
        return error.UnknownCommand;
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
    const features = [_]HostGatedFeature{ .ssh, .install_cli, .control_socket };

    // Windows: 셋 다 막히고 이유 문구가 있다(빈 문자열이면 사용자가 무슨 일인지 못 안다).
    for (features) |f| {
        const reason = hostGateReason(.windows, f) orelse return error.TestUnexpectedResult;
        try std.testing.expect(reason.len > 0);
    }

    // 다른 호스트: 셋 다 열려 있다. macOS/Linux 동작이 이 슬라이스로 바뀌지 않는다는 증거다.
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| {
        for (features) |f| try std.testing.expect(hostGateReason(os, f) == null);
    }

    // 백로그 슬라이스 번호를 문구에 담아 둔다 — "안 된다"만 말하고 어디서 하는지 안 알려주면 보고가 아니다.
    try std.testing.expect(std.mem.indexOf(u8, hostGateReason(.windows, .ssh).?, "W9") != null);
    try std.testing.expect(std.mem.indexOf(u8, hostGateReason(.windows, .install_cli).?, "W10") != null);
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
/// **색은 리터럴이다.** §2m.17 이 "스모크에 config 가 끼면 판정이 흐려진다" 로 정해 둔 규율이다.
fn runWin32EditorDrawSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru win32-editor-draw-smoke: Windows only\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const editor_view = maru.chrome.components.editor_view;

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
    const SelRange = struct { lo: usize, hi: usize };
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
    const Built = struct {
        frame: maru.renderer.RenderFrame,
        written: editor_view.frame.Written,
        cells: std.ArrayList(d3d11_cells.Cell),
        ops_text: usize,
        ops_fill: usize,
        ops_dropped: usize,

        fn deinit(self: *@This(), a: std.mem.Allocator) void {
            self.cells.deinit(a);
            self.frame.deinit(a);
        }
    };
    const build = struct {
        fn go(
            a: std.mem.Allocator,
            h: *draw_host.Host,
            ev: type,
            first_line: usize,
            ls: []const []const u8,
            sc: anytype,
            op_buf: []maru.chrome.draw.Op,
            tk: *const maru.chrome.Tokens,
            cl: maru.renderer.metal_frame.CellColors,
            v: maru.chrome.draw.Rect,
            inn: maru.chrome.draw.Rect,
            ins: i32,
            cw: u32,
            ch: u32,
            g: maru.terminal.Size,
            sel: ?SelRange,
            ss: anytype,
        ) !Built {
            // **선택을 행 축으로 자른다.** 산술은 중립이 소유한다(`selection_marks`) — macOS 와
            // Windows 가 각자 적으면 경계 셋(줄 시작·줄 끝·선택 양끝) 중 하나가 조용히 갈린다.
            //
            // 행 → 문서 줄 대응은 **여기서** 푼다(랩·접힘이 없으므로 순차다). 그것이 축을 정하는
            // 일이고, 그 파일 머리말이 호출자 몫이라고 적어 둔 자리다.
            var sel_marks: ?[]const []const ev.frame.Mark = null;
            if (sel) |sr| {
                const n = @min(ss.rows.len, ls.len -| first_line);
                for (0..n) |i| {
                    const li = first_line + i;
                    ss.spans[i] = .{ .start = ss.line_starts[li], .end = ss.line_starts[li] + ls[li].len };
                }
                ev.selection_marks.build(sr.lo, sr.hi, ss.spans[0..n], ss.rows[0..n], ss.buf[0..n]);
                sel_marks = ss.rows[0..n];
            }

            const w = ev.diff_frame.buildSide(
                .{ .lines = ls, .total_lines = ls.len, .selection_marks = sel_marks },
                .{
                    .first_line = first_line,
                    .wrap = false,
                    .tab_width = 4,
                    .cell_w_px = @intCast(cw),
                    .cell_h_px = @intCast(ch),
                    .font_px = @intCast(ch),
                },
                inn,
                // **배경은 안쪽 사각보다 사방 `inset` 만큼 넓다.** 제품은 내용을 pane 원점 + inset 에
                // 놓고 배경을 pane 원점에 놓아 딱 맞는데, 스모크는 내용을 창 (0,0) 에 놓으므로 배경이
                // 음수로 시작하는 만큼 폭·높이도 늘려야 오른쪽·아래가 안 빈다(초록 대조군 5,844 px).
                .{ .x = -ins, .y = -ins, .w = v.w + ev.frame.content_inset_px * 2, .h = v.h + ev.frame.content_inset_px * 2 },
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
            const prepared = try h.prepare(a, dl);
            var built = Built{
                .frame = prepared.frame,
                .written = w,
                .cells = .empty,
                .ops_text = n_text,
                .ops_fill = n_fill,
                .ops_dropped = n_drop,
            };
            errdefer built.deinit(a);

            // **단색 사각(배경·스크롤바)을 글리프보다 먼저 넣는다** — 그리는 순서가 곧 z 순서다.
            for (op_buf[0..w.ops]) |op| {
                const rect: maru.chrome.draw.Rect, const role: maru.chrome.tokens.ColorRole, const alpha: u8, const radii: [4]u16 = switch (op) {
                    .fill => |f| .{ f.rect, f.role, f.alpha, .{ 0, 0, 0, 0 } },
                    // **그라디언트·테두리는 아직 없다.** 이 셰이더에 그 계산이 없으므로 `solid` 가
                    // 아닌 것은 세어서 남긴다 — 조용히 단색으로 그리면 화면이 틀린 채로 그럴듯해진다.
                    .quad => |q| if (q.gradient == .solid and q.border_role == null)
                        .{ q.rect, q.fill_role, q.alpha, q.corner_radii }
                    else
                        continue,
                    else => continue,
                };
                const x0 = @max(rect.x, 0);
                const y0 = @max(rect.y, 0);
                const x1 = @min(rect.x + @as(i32, @intCast(rect.w)), @as(i32, @intCast(v.w)));
                const y1 = @min(rect.y + @as(i32, @intCast(rect.h)), @as(i32, @intCast(v.h)));
                if (x1 <= x0 or y1 <= y0) continue;
                const rgb = tk.get(role);
                const argb = (@as(u32, alpha) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
                try built.cells.append(a, d3d11_cells.solidCell(
                    @floatFromInt(x0),
                    @floatFromInt(y0),
                    @floatFromInt(x1 - x0),
                    @floatFromInt(y1 - y0),
                    d3d11_cells.colorFromArgb(argb),
                    .{ @floatFromInt(radii[0]), @floatFromInt(radii[1]), @floatFromInt(radii[2]), @floatFromInt(radii[3]) },
                ));
            }
            _ = try h.appendGlyphCells(a, built.frame, cl, &built.cells);
            return built;
        }
    }.go;

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
        var probe = try build(allocator, &host, editor_view, 0, lines.items, scratch, ops, &tokens, colors, view, inner, inset, cell_w, cell_h, grid, null, sel_scratch);
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

            var built = try build(allocator, &host, editor_view, first_line, lines.items, scratch, ops, &tokens, colors, view, inner, inset, cell_w, cell_h, grid, null, sel_scratch);
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
        var built_sel = try build(allocator, &host, editor_view, 0, lines.items, scratch, ops, &tokens, colors, view, inner, inset, cell_w, cell_h, grid, .{ .lo = lo, .hi = hi }, sel_scratch);
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
    var sel_range: ?SelRange = null;
    var caret_at: ?maru.chrome.components.editor_view.hit.Point = null;
    var built = try build(allocator, &host, editor_view, first_line, lines.items, scratch, ops, &tokens, colors, view, inner, inset, cell_w, cell_h, grid, sel_range, sel_scratch);
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
            var next_built = build(allocator, &host, editor_view, first_line, lines.items, scratch, ops, &tokens, colors, view, inner, inset, cell_w, cell_h, grid, sel_range, sel_scratch) catch built;
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
                const next_built = try build(allocator, &host, editor_view, first_line, lines.items, scratch, ops, &tokens, colors, view, inner, inset, cell_w, cell_h, grid, null, sel_scratch);
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
