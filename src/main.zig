const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
// W7.1 Win32 창. **최상위에서 import한다** — Win32를 부르는 본문은 `builtin.os.tag` 비교가 comptime 참이라
// 다른 타깃에서 의미 분석 자체가 되지 않는다(`cli/control_client.zig`의 게이트와 같은 원리).
const win32_window = @import("platform/windows/win32_window.zig");
// W7.2a D3D11+DXGI 표시 경로. 창과 같은 이유로 최상위 import다(위 주석).
const d3d11_present = @import("platform/windows/d3d11_present.zig");
// W7.2b 셀 인스턴스 드로우.
const d3d11_cells = @import("platform/windows/d3d11_cells.zig");
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
/// 반환 슬라이스는 **환경 블록을 borrow**한다(`std.mem.span` — free하지 않는다). 프로세스 수명 동안
/// 유효하고, `main`이 환경을 바꾸지 않으므로 안전하다.
fn hostHomeDir() ?[]const u8 {
    const home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null;
    const userprofile: ?[]const u8 = if (std.c.getenv("USERPROFILE")) |u| std.mem.span(u) else null;
    return maru.user_paths.homeDirFor(@import("builtin").os.tag, home, userprofile);
}

/// `maru win32-window-smoke` — W7.1이 실제로 무엇을 하는지 사람이 눈으로 확인하는 자리.
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
        try stderr.writeAll("maru win32-window-smoke: Windows 전용입니다\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.1 window smoke)");
    var window = win32_window.Window.create(allocator, title, 960, 600) catch |err| {
        try stderr.print("maru win32-window-smoke: 창을 만들지 못했습니다({s}, Win32 오류 {d})\n", .{ @errorName(err), win32_window.last_create_error });
        try stderr.writeAll("  대화형 데스크톱이 없는 환경(CI·서비스·원격 자동화)에서는 정상입니다 — 평범한 세션에서 실행하세요.\n");
        // 오류 8을 따로 말한다. 이름은 메모리지만 실제로는 **데스크톱 힙** 고갈이고, 그때는 세션 전체가
        // 창을 못 만든다(실측: 고아 프로세스 8,606개가 쌓여 notepad조차 뜨지 않았다). 이 구분이 없으면
        // 앱 버그로 오진한다 — 우리가 그렇게 한 번 헤맸다.
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  오류 8(ERROR_NOT_ENOUGH_MEMORY)은 보통 데스크톱 힙 고갈입니다 — 이 세션의 프로세스 수를 확인하세요.\n");
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
    try stdout.writeAll("visible UI: 창만 뜬다. 그리기는 W7.2(D3D11+DXGI), 입력은 W7.4다.\n");
    try stdout.flush();
}

/// `maru d3d11-present-smoke` — W7.2a. **창이 GPU로 칠해지는 것까지**를 사람이 눈으로 확인하는 자리.
///
/// W7.1 스모크와 갈라 둔 이유: 실패가 창에서 났는지 표시 경로에서 났는지 한 층씩 보여야 한다. 여기서
/// 증명하는 것은 "D3D11 디바이스와 DXGI 스왑체인이 서고, 리사이즈를 따라가고, present가 화면에 닿는다"
/// 까지다. 셀·글리프는 W7.2b다 — 그래서 지금은 **테마 배경 한 색**만 칠한다.
fn runD3d11PresentSmoke(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru d3d11-present-smoke: Windows 전용입니다\n");
        try stderr.flush();
        return error.UnknownCommand;
    }
    const title = std.unicode.utf8ToUtf16LeStringLiteral("maru (W7.2a D3D11 present smoke)");
    var window = win32_window.Window.create(allocator, title, 960, 600) catch |err| {
        try stderr.print("maru d3d11-present-smoke: 창을 만들지 못했습니다({s}, Win32 오류 {d})\n", .{ @errorName(err), win32_window.last_create_error });
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  오류 8(ERROR_NOT_ENOUGH_MEMORY)은 보통 데스크톱 힙 고갈입니다 — 이 세션의 프로세스 수를 확인하세요.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    // `orelse`의 두 갈래는 타입이 같아야 한다 — 익명 리터럴은 `?ClientSize`의 payload로 추론되지 않는다.
    const initial = window.clientSize() orelse win32_window.ClientSize{ .width_px = 960, .height_px = 600 };
    var present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
        try stderr.print("maru d3d11-present-smoke: 표시 경로를 세우지 못했습니다({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
        try stderr.writeAll("  GPU/드라이버가 D3D11을 못 주는 환경(일부 CI·원격 세션)에서는 정상입니다.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer present.destroy();
    // 창이 표시 대상을 **만들지 않고 받는다**(W7.1의 이음매). 여기가 그것을 채우는 유일한 자리다.
    window.present.opaque_handle = @ptrCast(present);

    // 터미널 테마 기본 배경과 같은 표현(0xAARRGGBB)을 쓴다 — W7.2c가 실제 `terminal_bg`를 넣을 자리다.
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
                    try stderr.print("resize 실패: {s} (HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
                    try stderr.flush();
                    return error.UnknownCommand;
                };
            },
            .paint => {},
            .close_requested => close_requested = true,
        };
        present.clearAndPresent(clear, false) catch |err| {
            try stderr.print("present 실패: {s} (HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
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
    try stdout.writeAll("visible UI: 창이 테마 배경색으로 칠해진다. 셀·글리프는 W7.2b, 입력은 W7.4다.\n");
    try stdout.flush();
}

/// W7.2b 스모크가 아틀라스에 채워 넣는 코드포인트. **폰트를 쓰지 않는다** — `renderer.synthesizeGlyph`가
/// codepoint에서 직접 픽셀을 만드는 것들만 골랐다(box-drawing·block·braille). 그래서 W7.3(DirectWrite)
/// 전에도 "아틀라스에서 커버리지를 읽어 셀에 칠한다"는 경로 전체가 실제 픽셀로 검증된다.
const cells_smoke_codepoints = [_]u32{
    0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518, 0x251C, 0x2524, // 직선·모서리·T
    0x252C, 0x2534, 0x253C, 0x2550, 0x2551, 0x2554, 0x2557, 0x255A, // 사거리·이중선
    0x2588, 0x2592, 0x2584, 0x2580, 0x258C, 0x2590, 0x2596, 0x259A, // block·shade·half
    0x28FF, 0x2801, 0x2847, 0x28B6, // braille
};

/// `maru d3d11-cells-smoke` — W7.2b. **글리프가 화면에 나오는 것까지**를 사람이 눈으로 확인하는 자리.
///
/// W7.2a가 "창이 한 색으로 칠해진다"였다면 여기는 "셀 격자에 배경색과 글리프가 각각 제자리에 그려진다"다.
/// 아직 실제 터미널 화면이 아니다(W7.2c가 `app.host` 프레임을 물린다) — 여기서 그리는 것은 이 스모크가
/// 직접 만든 격자다. 그래도 아틀라스 업로드·UV 변환·인스턴스 드로우·블렌드가 전부 진짜 경로다.
fn runD3d11CellsSmoke(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (@import("builtin").os.tag != .windows) {
        try stderr.writeAll("maru d3d11-cells-smoke: Windows 전용입니다\n");
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
    // 실제 덮인 픽셀은 0이었다(그래서 이 수를 따로 세어 보고한다 — 안 그러면 성공으로 보인다).
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
        try stderr.print("maru d3d11-cells-smoke: 창을 만들지 못했습니다({s}, Win32 오류 {d})\n", .{ @errorName(err), win32_window.last_create_error });
        if (win32_window.last_create_error == 8)
            try stderr.writeAll("  오류 8(ERROR_NOT_ENOUGH_MEMORY)은 보통 데스크톱 힙 고갈입니다 — 이 세션의 프로세스 수를 확인하세요.\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer window.destroy();
    window.show();

    const initial = window.clientSize() orelse win32_window.ClientSize{ .width_px = 960, .height_px = 600 };
    var present = d3d11_present.Present.create(allocator, window.hwnd, initial.width_px, initial.height_px) catch |err| {
        try stderr.print("maru d3d11-cells-smoke: 표시 경로를 세우지 못했습니다({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_present.last_hresult)) });
        try stderr.flush();
        return error.UnknownCommand;
    };
    defer present.destroy();
    window.present.opaque_handle = @ptrCast(present);

    var pipeline = d3d11_cells.CellPipeline.create(allocator, present.device, present.context, atlas_w, atlas_h, atlas_pixels) catch |err| {
        try stderr.print("maru d3d11-cells-smoke: 셀 파이프라인을 세우지 못했습니다({s}, HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_cells.last_hresult)) });
        if (d3d11_cells.shaderError().len > 0)
            try stderr.print("  셰이더 컴파일러: {s}\n", .{d3d11_cells.shaderError()});
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
        };

        const size = win32_window.cellsForClient(present.width_px, present.height_px, cell_w, cell_h) orelse continue;
        cells.clearRetainingCapacity();
        var row: u32 = 0;
        while (row < size.rows) : (row += 1) {
            var col: u32 = 0;
            while (col < size.cols) : (col += 1) {
                // 격자무늬 배경 — 배경 알파가 실제로 판정에 쓰이는지 보이게 한다. 알파 0인 셀은
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
            try stderr.print("draw 실패: {s} (HRESULT 0x{X:0>8})\n", .{ @errorName(err), @as(u32, @bitCast(d3d11_cells.last_hresult)) });
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
    try stdout.writeAll("visible UI: 셀 격자에 배경색과 합성 글리프가 그려진다. 폰트 글리프는 W7.3, 실제 터미널 화면은 W7.2c다.\n");
    try stdout.flush();
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
            "note: 이 플랫폼엔 아직 PTY 백엔드가 없어 `demo`·`app-pty-*`는 못 돕니다 " ++
                "(docs/plans/windows-platform.md W4 — ConPTY).\n" ++
                "      `app-smoke`·`app-loop-smoke`·`terminfo`는 지금도 동작합니다.\n",
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
    // GUI가 붙기 전에도 실제 PTY -> reader -> runtime -> snapshot 경로를 사람이
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
    // 아직 실제 AppKit/Metal UI를 띄우지 않는다. 이 smoke는 app host가
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
    // 실제 NSApplication loop를 붙이기 전에 반복 tick 계약을 먼저 고정한다.
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
    // 실제 PTY reader thread를 쓰지만 아직 native window loop는 아니다.
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
    // 이 smoke는 사용자의 실제 interactive shell을 실행하지만, 제품 UI는 아직 아니다.
    // 입력은 FrameLoop.handleKeyEvent를 통과해 PTY로 내려가므로, shell과 app input 경계가
    // 같이 검증된다. dotfile/prompt 영향이 있어 기본 check에는 넣지 않는다.
    // 각본은 셸마다 달라 `app/fixture_script.zig`가 단일 출처다 — 표식·인자·입력이 한 곳에 있어야
    // "입력은 POSIX인데 기대값만 고쳤다" 같은 어긋남이 안 생긴다.
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
    // 실제 PTY output이 app host renderer frame까지 들어가는지 확인한다.
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
        .ssh => "maru ssh는 Windows에서 아직 지원되지 않습니다 (docs/plans/windows-platform.md W9).",
        .install_cli => "maru install-cli는 Windows에서 아직 지원되지 않습니다 (docs/plans/windows-platform.md W10).",
        // 문구의 단일 출처는 그 게이트를 실제로 강제하는 곳이다 — 접착이 `cli/control_client.zig`로 옮겨 갔으므로
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
    // ssh로 exec한다. 순수 로직(파싱·스크립트·argv)은 maru.cli.ssh가 갖고, 여기선 인자 수집과 실제
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
    // heap이 손상된다. built로 실제 채운 개수를 세어 채운 것만 free한다(ArgvStorage의 initialized 가드와 동치).
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
    try stderr.writeAll("maru ssh: /bin/sh exec에 실패했습니다\n");
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
    // 실제 mkdir/symlink(std.c)만 한다. sudo가 필요 없는 user-level 경로라 권한 상승이 없다.
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    const home = hostHomeDir() orelse {
        try stderr.writeAll("maru install-cli: 홈 디렉터리를 찾지 못해 설치 위치를 정할 수 없습니다($HOME)\n");
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
        try stderr.print("maru install-cli: symlink 실패: {s}\n", .{link});
        try stderr.flush();
        return error.UnknownCommand;
    }

    try stdout.print("maru CLI 설치 완료: {s} -> {s}\n", .{ link, exe_path });

    // bin 디렉터리가 PATH에 없으면 추가 방법을 안내한다.
    if (std.c.getenv("PATH")) |path_z| {
        if (!maru.cli.install.pathContainsDir(std.mem.span(path_z), bindir)) {
            try stdout.print(
                "\n주의: {s}가 PATH에 없습니다. 셸 설정(~/.zshrc 등)에 아래를 추가하세요:\n  export PATH=\"{s}:$PATH\"\n",
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
        try stderr.writeAll("maru terminfo: 홈 디렉터리를 찾지 못해 캐시 위치를 정할 수 없습니다($HOME" ++
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
    const xdg_raw = if (std.c.getenv("XDG_CACHE_HOME")) |x| std.mem.span(x) else null;
    const local_raw = if (std.c.getenv("LOCALAPPDATA")) |l| std.mem.span(l) else null;
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
            try stdout.print("maru terminfo 캐시: {s}\n", .{dir});
            try stdout.flush(); // system()이 fd로 직접 쓰므로 버퍼를 먼저 비운다.
            // **Windows에서는 상태를 알 수 없다 — 모른다고 말한다.** 프로브가
            // `TERMINFO=<dir> infocmp xterm-maru`인데 그 `VAR=값 명령` 접두는 POSIX 문법이고,
            // `system()`은 여기서 `%COMSPEC%`(cmd.exe)로 간다(실측: `'TERMINFO' is not recognized`).
            // 즉 프로브가 **항상 실패**해서, 예전 코드는 캐시가 실제로 컴파일돼 있어도 늘
            // "아직 컴파일 안 됨"이라고 단언했다 — 모르는 것을 아는 것처럼 말하는 쪽이 더 나쁘다.
            if (!posixShellCommandsWork()) {
                try stdout.writeAll("상태: 알 수 없음 — 상태 확인이 POSIX 셸을 요구하는데 이 호스트의 `system()`은 cmd.exe로 갑니다\n");
                try stdout.flush();
                return;
            }
            const cmd = try maru.terminfo_cache.statusCommand(allocator, dir);
            defer allocator.free(cmd);
            if (system(cmd.ptr) == 0) {
                try stdout.writeAll("상태: xterm-maru 컴파일됨 (config term = \"xterm-maru\"면 이 캐시를 TERMINFO로 쓴다)\n");
            } else {
                try stdout.writeAll("상태: 아직 컴파일 안 됨 — maru를 한 번 실행하면 자동 컴파일되거나, `maru terminfo --refresh`로 지금 컴파일한다\n");
            }
        },
        // 업데이트로 terminfo 캡이 바뀐 뒤 등, 캐시를 강제로 비우고 다시 컴파일한다(보통은 자동 stale 감지로
        // 불필요하지만 강제·복구용). tic 경고/오류는 사용자에게 그대로 보인다.
        .refresh => {
            const cmd = try maru.terminfo_cache.refreshCommand(allocator, dir, maru.terminfo_cache.version());
            defer allocator.free(cmd);
            try stdout.print("maru terminfo 캐시 재컴파일: {s}\n", .{dir});
            try stdout.flush();
            if (system(cmd.ptr) == 0) {
                try stdout.writeAll("완료: xterm-maru 재컴파일됨\n");
            } else {
                // Windows에서는 원인이 하나 더 있다. `system()`은 여기서 `/bin/sh`가 아니라 **cmd.exe**로
                // 가는데(msvcrt), 재컴파일 명령은 `rm -rf`·`mkdir -p`·`printf`를 쓰는 POSIX 스크립트다.
                // 실측(PowerShell·cmd): 그 넷도 `tic`도 PATH에 없다 — 둘 다 git-bash의 `/usr/bin`에만 있다.
                // 그래서 tic만 가리키면 사용자가 tic을 깔아도 여전히 실패한다. 계약 §8 "홈·캐시 위치" 참조.
                try stderr.writeAll(if (!posixShellCommandsWork())
                    "maru terminfo: 재컴파일은 이 호스트에서 지원되지 않습니다 — 재컴파일 명령이 POSIX 셸 문법(`d=...; rm -rf ...`)인데\n" ++
                        "  `system()`이 cmd.exe로 갑니다. **git-bash에서 maru를 띄워도 같습니다**(셸이 아니라 %COMSPEC%가 정합니다).\n" ++
                        "  재컴파일 없이도 터미널은 xterm-256color로 폴백해 정상 동작합니다.\n"
                else
                    "maru terminfo: 재컴파일 실패 — tic(ncurses)이 설치돼 있는지 확인하세요(셸에선 xterm-256color로 폴백)\n");
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
                try stderr.print("maru terminfo: 캐시 삭제 실패 — {s}\n", .{dir});
                if (!posixShellCommandsWork())
                    // 이 명령만은 단일 외부 명령(`rm -rf '<경로>'`)이라 cmd.exe도 실행할 수 있다 —
                    // `rm.exe`가 PATH에 있으면(git 설치본) 된다. 그래서 안내가 "셸을 바꾸라"가 아니라
                    // "PATH에 rm이 있느냐"다(재컴파일 쪽과 원인이 다르다).
                    try stderr.writeAll("  `rm`이 PATH에 없습니다(git 설치본의 usr 밑에 있습니다) — 해당 폴더를 직접 지워도 됩니다\n");
                try stderr.flush();
                return error.UnknownCommand;
            }
            try stdout.print("maru terminfo 캐시 삭제: {s}\n", .{dir});
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
                try stderr.print("maru trace anonymize: '{s}' 읽기 실패 ({s})\n", .{ an.input, @errorName(e) });
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
                try stderr.print("maru trace anonymize: 변환 실패 ({s}) — 유효한 maru.trace.v1인가요?\n", .{@errorName(e)});
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
                try stderr.writeAll("경고: 익명화 후에도 민감 할당(TOKEN/SECRET/… =값)이 남아 있습니다 — 커밋 전 수동 제거 필요\n");
                try stderr.flush();
            }
        },
    }
    try stdout.flush();
}

/// `maru sessions ...` / `maru session ...` 두 컨트롤 플레인 read-only 명령의 얇은 접착(Track C 1d·A2a). 순수
/// 파싱·요청 조립·응답 포맷·소켓 발견 정책은 `maru.cli.sessions`가 갖고, 여긴 인자 수집·getenv/readdir/소켓 syscall·
/// stdout/stderr I/O만 한다(ssh/terminfo와 같은 결 — §11 "소켓 syscall L4·CLI는 src/cli·main 얇게"). `--help`는
/// 구현된 명령만 담은 help를 낸다(§11 CLI help gate). **A2a**: 요청은 이제 실제로 컨트롤 소켓에 connect해 왕복한다 —
/// 결정론 경로(`<cache>/maru/control`)에서 단일 인스턴스 소켓을 찾아(§4.2) `buildRequestBytes` 전송 → hello skip →
/// 응답 프레임(1a `Framer`) 수신 → `renderResponse`로 사람이 읽게 낸다. 살아있는 인스턴스가 없거나 connect가 실패하면
/// crash/트레이스 없이 graceful하게 안내하고 종료한다. 서버가 소켓을 실제로 띄우는 배선(accept-loop 스레드·메인
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

/// `sessions list`/`session get` 요청을 실제 컨트롤 소켓에 왕복한다(A2a). 소켓 흐름은 `cli.control_client`,
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
/// 실행하면 실패"가 된다. 그 상수와 실제 spawn 실패의 일치는 `pty/session.zig` 테스트가 지킨다.
/// 백엔드가 있는데 spawn이 실패하는 경우는 여기 안 걸리고 그대로 오류로 남는다(진짜 오류는 트레이스가 맞다).
fn ptyBackendMissing(stderr: *std.Io.Writer) error{UnknownCommand} {
    stderr.writeAll(
        "이 명령은 PTY 백엔드가 필요한데 이 플랫폼에는 아직 없습니다 " ++
            "(docs/plans/windows-platform.md W4 — ConPTY).\n" ++
            "PTY 없이 도는 것: maru app-smoke · maru app-loop-smoke · maru terminfo\n",
    ) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

fn writeSessionCliUsage(stderr: *std.Io.Writer, which: SessionCli, err: maru.cli.sessions.ParseError) !void {
    const reason = switch (err) {
        error.MissingSubcommand => "서브커맨드가 필요합니다",
        error.UnknownSubcommand => "알 수 없는 서브커맨드입니다",
        error.MissingSurfaceId => "surface id가 필요합니다",
        error.InvalidSurfaceId => "surface id는 음이 아닌 정수여야 합니다",
        error.MissingWindowValue => "--window 에는 값이 필요합니다",
        error.InvalidWindowValue => "--window 값은 음이 아닌 정수여야 합니다",
        error.UnknownOption => "알 수 없는 옵션입니다",
        error.UnexpectedArgument => "인자가 너무 많습니다",
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
    // 반대 방향 — "안내를 띄우는 호스트에서는 실행이 실제로 실패한다" — 은 그 사실이 사는 곳
    // (`src/pty/session.zig`)에서 spawn을 직접 불러 지킨다. 여기서 타입을 다시 비교하면 정의를 베껴 쓴
    // 동어반복이라 아무것도 못 잡는다.
}
