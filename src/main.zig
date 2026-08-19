const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const file_tree_backend = @import("platform/macos/file_tree_backend.zig"); // 파일 트리 스캔 — 이름과 달리 모든 호스트에서 돈다(계약 §2m.3)
// W7.1 Win32 창. **최상위에서 import한다** — Win32를 부르는 본문은 `builtin.os.tag` 비교가 comptime 참이라
// 다른 타깃에서 의미 분석 자체가 되지 않는다(`cli/control_client.zig`의 게이트와 같은 원리).
const win32_window = @import("platform/windows/win32_window.zig");
// W7.2a D3D11+DXGI 표시 경로. 창과 같은 이유로 최상위 import다(위 주석).
const d3d11_present = @import("platform/windows/d3d11_present.zig");
// W7.2b 셀 인스턴스 드로우.
const d3d11_cells = @import("platform/windows/d3d11_cells.zig");
// W7.3 DirectWrite 글리프 래스터라이저.
const dwrite_font = @import("platform/windows/dwrite_font.zig");
// W7.2c 중립 텍스트 계약 어댑터와 프레임 빌더.
const win32_text = @import("platform/windows/win32_text.zig");
const win32_terminal = @import("platform/windows/win32_terminal.zig");
// W7.4a Win32 키 입력 → 중립 KeyEvent.
const win32_keys = @import("platform/windows/win32_keys.zig");
// W7.4b Win32 클립보드(OSC 52 배수 + 붙여넣기).
const win32_clipboard = @import("platform/windows/win32_clipboard.zig");
// W7.4d Win32 마우스 규칙(선택·스크롤·리포팅) — 전부 순수 함수다.
const win32_mouse = @import("platform/windows/win32_mouse.zig");
// 짧은 대기(스모크 전용). `app/live_pty.zig`가 같은 이유로 같은 것을 쓴다 — std에 노출이 없다.
extern "c" fn usleep(usec: c_uint) c_int;
const session_host_entrypoint = @import("platform/macos/session_host/entrypoint.zig");
const session_host_build_options = @import("session_host_build_options");
const session_host_admin_cli = if (builtin.os.tag == .macos)
    @import("platform/macos/session_host/admin_cli.zig")
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

    if (std.mem.eql(u8, command, "win32-file-tree-smoke")) {
        try runWin32FileTreeSmoke(io, allocator, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, command, "win32-terminal-smoke")) {
        if (!maru.pty.backend_available) return ptyBackendMissing(stderr);
        try runWin32TerminalSmoke(io, allocator, stdout, stderr);
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
fn runWin32TerminalSmoke(io: std.Io, allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
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

    // ── PTY와 중립 프레임 루프 ─────────────────────────────────────────────────────────────
    const start = win32_window.cellsForClient(initial.width_px, initial.height_px, cell_w, cell_h) orelse
        maru.terminal.Size{ .cols = 80, .rows = 24 };
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

    var cells: std.ArrayList(d3d11_cells.Cell) = .empty;
    defer cells.deinit(allocator);

    const colors = maru.renderer.metal_frame.CellColors{
        .default_fg = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 },
        .default_bg = .{ .r = 0x1E, .g = 0x24, .b = 0x30 },
        // **커서를 켠다.** 기본값 `null`은 "커서를 투영하지 않는다"이고(그 doc: 아틀라스 픽셀을 그대로
        // 검증하는 골든 스모크가 커서 블록에 흔들리지 않게 하려는 것), 터미널 화면에는 커서가 있어야 한다.
        // 켜지 않으면 화면이 그럴듯해 보여도 커서 오버레이 투영 경로가 한 번도 안 돈다.
        .cursor = .{
            .block = .{ .r = 0xD8, .g = 0xE0, .b = 0xF0 },
            .text = .{ .r = 0x1E, .g = 0x24, .b = 0x30 },
        },
    };
    const clear = d3d11_present.clearColorFromArgb(0xFF1E2430);

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
    var close_requested = false;
    var ended = false;
    // **각본을 보내지 않는다.** 이 스모크는 사람이 타이핑하는 자리다 — fixture 각본은 `exit`으로 끝나서
    // 셸이 죽고, 그 뒤 키는 죽은 PTY 에 쓰인다(실측: keys_to_shell=16 인데 화면에 안 나왔다).
    // 각본으로 끝내는 검증은 `win32-frame-smoke`(W7.2c-1)가 한다.
    var spins: usize = 0;
    while (spins < 600 and !window.quit_requested and !close_requested) : (spins += 1) {
        for (window.poll()) |ev| switch (ev) {
            .resized => |r| {
                try present.resize(r.width_px, r.height_px);
                // **터미널 격자도 바꾼다.** 스왑체인만 맞추면 셸이 옛 크기로 계속 출력해 줄이 어긋난다.
                if (win32_window.cellsForClient(r.width_px, r.height_px, cell_w, cell_h)) |size|
                    loop.resizeActiveSurface(size) catch {};
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

        // ⑶ 중립 투영 → D3D11 셀.
        const native = try maru.renderer.metal_frame.buildNativeCellsFromGlyphQuads(
            allocator,
            tick.frame.render_frame.glyph_quad_frame,
            tick.frame.render_frame.draw_list.cells,
            colors,
        );
        defer allocator.free(native);

        cells.clearRetainingCapacity();
        try cells.ensureTotalCapacity(allocator, native.len);
        for (native) |n| cells.appendAssumeCapacity(win32_terminal.cellFromNative(n, cell_w, cell_h, atlas_w, atlas_h));
        last_cells = cells.items.len;

        try present.beginFrame(clear);
        try pipeline.draw(cells.items, present.width_px, present.height_px);
        try present.present(false);
        frames += 1;
        _ = usleep(16_000);
    }
    if (close_requested) window.requestClose();

    try stdout.writeAll("maru.win32-terminal-smoke.v1\n");
    try stdout.print("font_family={s}\n", .{raster.family});
    try stdout.print("cell_px={d}x{d}\n", .{ cell_w, cell_h });
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
    try stdout.print("mouse_events={d} reports={d} selections={d} extends={d} words={d} lines={d}\n", .{ mouse_events, mouse_reports, selections, extends, word_selections, line_selections });
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
