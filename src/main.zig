const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
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
        // PTY 백엔드가 없는 호스트에서 `demo`·`app-pty-*`를 부르면 `UnsupportedPtySession`이 이 오류를 낸다
        // (`src/pty/session.zig` — 그 타입이 이 오류의 **유일한 출처**다). 위 sentinel과 같은 이유로 여기서
        // 잡는다: 전파시키면 Zig가 6프레임 스택 트레이스를 덤프해 사용자에겐 crash로 보인다(실측 19줄).
        //
        // **OS가 아니라 오류 값으로 판정한다.** 그래야 ⑴ macOS는 이 오류가 아예 안 나므로 동작이 안 바뀌고
        // ⑵ 백엔드 없는 다른 호스트도 같은 안내를 받으며 ⑶ ConPTY(W4)가 들어오는 날 이 갈래가 **저절로
        // 죽는다**(오류가 더는 반환되지 않으므로). `builtin.os.tag`로 분기하면 W4 뒤에 누가 지워야 한다.
        error.UnsupportedPlatform => {
            stderr.print(
                "이 명령은 PTY 백엔드가 필요한데 이 플랫폼에는 아직 없습니다 " ++
                    "(docs/plans/windows-platform.md W4 — ConPTY).\n" ++
                    "PTY 없이 도는 것: maru app-smoke · maru app-loop-smoke · maru terminfo\n",
                .{},
            ) catch {};
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
        try runDemo(io, allocator, stdout);
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
        try runAppPtyLoopSmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "app-pty-interactive-loop-smoke")) {
        try runAppPtyInteractiveLoopSmoke(io, allocator, stdout);
        return;
    }

    if (std.mem.eql(u8, command, "app-pty-smoke")) {
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
        try runBrowserCli(io, allocator, &args, stdout, stderr);
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
    const marker = "MARU_APP_PTY_INTERACTIVE_LOOP_OK";
    const config: maru.app.AppPtyLoopSmokeConfig = .{
        .artifact_dir = maru.app.pty_loop_smoke.default_interactive_artifact_dir,
        .command = maru.pty.resolveInteractiveShell(),
        .args = &.{"-i"},
        .expected_text = marker,
        .interactive_shell = true,
        .scripted_input = "printf 'MARU_APP_PTY_INTERACTIVE_LOOP_OK\\n'; exit\n",
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
        .control_socket => "Windows에서는 컨트롤 소켓이 아직 지원되지 않습니다",
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
        const home = std.c.getenv("HOME") orelse break :blk "";
        const dest = maru.cli.ssh.destination(parsed.ssh_args) orelse break :blk "";
        break :blk maru.cli.ssh.controlSocketPath(allocator, std.mem.span(home), dest) catch |err| switch (err) {
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

    const home_z = std.c.getenv("HOME") orelse {
        try stderr.writeAll("maru install-cli: $HOME가 없어 설치 위치를 정할 수 없습니다\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    const home = std.mem.span(home_z);

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

    const home_z = std.c.getenv("HOME") orelse {
        try stderr.writeAll("maru terminfo: $HOME가 없어 캐시 위치를 정할 수 없습니다\n");
        try stderr.flush();
        return error.UnknownCommand;
    };
    // 셸 명령과 같은 XDG 규칙으로 캐시 경로를 보여준다(둘이 같은 위치로 resolve).
    const xdg = if (std.c.getenv("XDG_CACHE_HOME")) |x| std.mem.span(x) else null;
    const dir = try maru.terminfo_cache.cacheDirZ(allocator, xdg, std.mem.span(home_z));
    defer allocator.free(dir);

    switch (action) {
        // 스크립트에서 캐시 경로만 필요할 때(예: 지우기 자동화). 경로만 한 줄 출력한다.
        .path => try stdout.print("{s}\n", .{dir}),
        // 캐시가 컴파일돼 xterm-maru가 해석되는지 보고한다(아무것도 바꾸지 않는 안전 기본).
        .status => {
            const cmd = try maru.terminfo_cache.statusCommand(allocator);
            defer allocator.free(cmd);
            try stdout.print("maru terminfo 캐시: {s}\n", .{dir});
            try stdout.flush(); // system()이 fd로 직접 쓰므로 버퍼를 먼저 비운다.
            if (system(cmd.ptr) == 0) {
                try stdout.writeAll("상태: xterm-maru 컴파일됨 (config term = \"xterm-maru\"면 이 캐시를 TERMINFO로 쓴다)\n");
            } else {
                try stdout.writeAll("상태: 아직 컴파일 안 됨 — maru를 한 번 실행하면 자동 컴파일되거나, `maru terminfo --refresh`로 지금 컴파일한다\n");
            }
        },
        // 업데이트로 terminfo 캡이 바뀐 뒤 등, 캐시를 강제로 비우고 다시 컴파일한다(보통은 자동 stale 감지로
        // 불필요하지만 강제·복구용). tic 경고/오류는 사용자에게 그대로 보인다.
        .refresh => {
            const cmd = try maru.terminfo_cache.refreshCommand(allocator, maru.terminfo_cache.version());
            defer allocator.free(cmd);
            try stdout.print("maru terminfo 캐시 재컴파일: {s}\n", .{dir});
            try stdout.flush();
            if (system(cmd.ptr) == 0) {
                try stdout.writeAll("완료: xterm-maru 재컴파일됨\n");
            } else {
                try stderr.writeAll("maru terminfo: 재컴파일 실패 — tic(ncurses)이 설치돼 있는지 확인하세요(셸에선 xterm-256color로 폴백)\n");
                try stderr.flush();
                return error.UnknownCommand;
            }
        },
        // 캐시 디렉터리를 통째로 지운다(다음 maru 실행이 자동 재컴파일).
        .clear => {
            const cmd = try maru.terminfo_cache.clearCommand(allocator);
            defer allocator.free(cmd);
            _ = system(cmd.ptr);
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

            const opts: maru.redact.AnonymizeOptions = .{
                .home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null,
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

/// `maru browser <cmd>` CLI(§9.6 CLI-2). runSessionCli 동형 — 인자 수집 → `cli.browser.parse` → help/요청. 소켓 왕복은
/// `runBrowserRequest`(공유 `fetchControlResponse`). browser 요청은 세션 cap 없이 §9.2 Model B로 확인 모달을 거친다.
fn runBrowserCli(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: anytype,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var collected: std.ArrayList([]const u8) = .empty;
    defer {
        for (collected.items) |s| allocator.free(s);
        collected.deinit(allocator);
    }
    while (args.next()) |a| try collected.append(allocator, try allocator.dupe(u8, a));

    const parsed = maru.cli.browser.parse(collected.items) catch |err| {
        try writeBrowserCliUsage(stderr, err);
        return error.UnknownCommand;
    };
    switch (parsed) {
        .help => {
            try stdout.writeAll(maru.cli.browser.browser_help);
            try stdout.flush();
        },
        .request => |req| try runBrowserRequest(io, allocator, req, stdout, stderr),
        .screenshot => |shot| try runBrowserScreenshot(io, allocator, shot, stdout, stderr),
    }
}

/// `maru browser` 파싱 실패 시 사유 + help를 stderr에 낸다(writeSessionCliUsage 동형).
fn writeBrowserCliUsage(stderr: *std.Io.Writer, err: maru.cli.browser.ParseError) !void {
    const reason = switch (err) {
        error.MissingSubcommand => "서브커맨드가 필요합니다",
        error.UnknownSubcommand => "알 수 없는 서브커맨드입니다",
        error.MissingSurface => "--surface <id> 가 필요합니다",
        error.InvalidSurface => "surface id는 음이 아닌 정수여야 합니다",
        error.MissingSurfaceValue => "--surface 에는 값이 필요합니다",
        error.MissingUrl => "navigate 에는 url이 필요합니다",
        error.MissingScript => "exec 에는 script가 필요합니다",
        error.MissingArgsValue => "exec --args 에는 JSON 배열 값이 필요합니다",
        error.InvalidArgs => "exec --args 는 유효한 JSON 배열이어야 합니다",
        error.MissingMaxResultBytesValue => "exec --max-result-bytes 에는 값이 필요합니다",
        error.InvalidMaxResultBytes => "exec --max-result-bytes 는 1..16777216 범위의 정수여야 합니다",
        error.MissingOutValue => "screenshot --out 에는 값이 필요합니다",
        error.MissingRectValue => "screenshot --rect 에는 값이 필요합니다",
        error.MissingScaleValue => "screenshot --scale 에는 값이 필요합니다",
        error.InvalidRect => "--rect 는 x,y,w,h (수치 4개, w/h>0) 형식이어야 합니다",
        error.InvalidScale => "--scale 은 양수여야 합니다",
        error.MissingName => "--name 이 필요합니다",
        error.MissingKey => "--key 가 필요합니다",
        error.MissingSelector => "--selector 가 필요합니다",
        error.MissingLocator => "click/type/scroll 에는 --selector 또는 --ref 중 하나가 필요합니다",
        error.ConflictingLocator => "click/type/scroll 에는 --selector와 --ref 중 하나만 지정할 수 있습니다",
        error.MissingWaitCondition => "wait 에는 --selector 또는 --load 중 하나가 필요합니다",
        error.ConflictingWaitCondition => "wait 에는 --selector와 --load 중 하나만 지정할 수 있습니다",
        error.MissingTimeoutValue => "wait --timeout 에는 값이 필요합니다",
        error.InvalidTimeout => "wait --timeout 은 1..25000 범위의 정수여야 합니다",
        error.MissingText => "type 에는 --text 가 필요합니다",
        error.MissingValue => "--value 가 필요합니다",
        error.MissingOptionValue => "옵션에 값이 필요합니다",
        error.MissingMaxDepthValue => "snapshot --max-depth 에는 값이 필요합니다",
        error.InvalidMaxDepth => "--max-depth 는 음이 아닌 정수여야 합니다",
        error.UnknownOption => "알 수 없는 옵션입니다",
        error.UnexpectedArgument => "인자가 너무 많습니다",
    };
    try stderr.print("maru browser: {s}\n\n", .{reason});
    try stderr.writeAll(maru.cli.browser.browser_help);
    try stderr.flush();
}

/// `sessions list`/`session get` 요청을 실제 컨트롤 소켓에 왕복한다(A2a). 소켓 흐름은 공유 `fetchControlResponse`,
/// 요청 조립·응답 렌더만 `maru.cli.sessions`. 살아있는 인스턴스가 없거나 connect 실패면 crash 없이 graceful 종료(exit 1).
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
    const resp = try fetchControlResponse(io, allocator, request_bytes, stderr);
    defer allocator.free(resp);
    try maru.cli.sessions.renderResponse(allocator, resp, kind, stdout);
    try stdout.flush();
}

/// `maru browser navigate/get-url/exec/get-cookies`를 컨트롤 소켓에 왕복한다(§9.6 CLI-2). sessions와 **동형**(같은
/// `fetchControlResponse` 소켓 흐름 공유) — 요청 조립·응답 렌더만 `cli.browser`. **grant 대기**: browser 요청은
/// 세션 cap 없어 needs_grant→서버 held→확인 모달. `fetchControlResponse`의 read가 사용자 클릭까지 블록한다(§9.2 Model B).
fn runBrowserRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    req: maru.cli.browser.Request,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (req == .exec) return runBrowserExecuteScript(io, allocator, req.exec, stdout, stderr);
    const cp = maru.session.control_plane;
    // §9.5.10 통일: inline이 method-특화 wrapper인 메서드(snapshot·console)는 bounded transfer라 chunk 재조립 러너로 간다.
    if (req == .snapshot) return runBrowserWrappedResult(io, allocator, req, cp.browser_snapshot_chunk_method, "snapshot", .snapshot, stdout, stderr);
    if (req == .console) return runBrowserWrappedResult(io, allocator, req, cp.browser_console_chunk_method, "console", .console, stdout, stderr);
    const kind = req.kind();
    const request_bytes = try maru.cli.browser.buildRequestBytes(allocator, req, .{ .number = 1 });
    defer allocator.free(request_bytes);
    const resp = try fetchControlResponse(io, allocator, request_bytes, stderr);
    defer allocator.free(resp);
    try maru.cli.browser.renderResponse(allocator, resp, kind, stdout);
    try stdout.flush();
}

fn runBrowserExecuteScript(
    io: std.Io,
    allocator: std.mem.Allocator,
    exec_cmd: maru.cli.browser.ExecCmd,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const request_id: maru.session.control_plane.Id = .{ .number = 1 };
    const request_bytes = maru.cli.browser.buildRequestBytes(allocator, .{ .exec = exec_cmd }, request_id) catch |err| switch (err) {
        error.InvalidArgs => return browserExecuteError(stderr, "--args 는 유효한 JSON 배열이어야 합니다"),
        else => return err,
    };
    defer allocator.free(request_bytes);
    const fd = try connectSendControl(io, allocator, request_bytes, stderr);
    defer _ = std.c.close(fd);

    var validator = maru.cli.browser.ExecuteScriptStreamValidator.init(allocator, request_id, exec_cmd.max_result_bytes);
    defer validator.deinit();
    // 결과를 메모리에 누적한다(validator가 ≤max_result_bytes로 상한). 이전엔 write-only atomic spool에 스트리밍한 뒤
    // 되읽어 검증/출력했으나, macOS는 `createFileAtomic` 핸들이 O_WRONLY(O_TMPFILE는 Linux 전용)라 pread가 EBADF로
    // 실패해 exec가 항상 에러였다. 버퍼링으로 read-back을 없앤다 — 공개는 검증 후 원자적 write로.
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var framer: maru.session.control_plane.Framer = .{};
    defer framer.deinit(allocator);
    var decode_scratch: [512 * 1024]u8 = undefined;
    done: while (true) {
        while (framer.next() catch null) |line| {
            switch (try validator.feed(line, &decode_scratch)) {
                .need_more => {},
                .chunk => |bytes| {
                    result.appendSlice(allocator, bytes) catch return error.OutOfMemory;
                },
                .inline_result => |bytes| {
                    result.appendSlice(allocator, bytes) catch return error.OutOfMemory;
                    break :done;
                },
                .done => break :done,
                .error_response => {
                    // 서버가 정상 JSON-RPC error(script_error·result_too_large·timeout·unauthorized 등) 반환 — 일반 "잘못된
                    // stream" 대신 실제 code/message를 stderr에 내고 exit 1(부분 result는 안 쓴다). renderResponse는 error
                    // 응답에서 kind를 안 쓴다(.exec는 표식일 뿐). 성공 결과만 stdout으로 나간다(계약 유지).
                    maru.cli.browser.renderResponse(allocator, line, .exec, stderr) catch {};
                    stderr.flush() catch {};
                    return error.UnknownCommand;
                },
                .failed => return browserExecuteError(stderr, "서버가 잘못된 executeScript stream을 반환했습니다"),
            }
        }
        var read_buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) return browserExecuteError(stderr, "서버가 응답을 끝내지 않았습니다");
        framer.push(allocator, read_buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    if (!validateJsonSlice(allocator, result.items))
        return browserExecuteError(stderr, "executeScript 결과가 strict JSON이 아닙니다");

    if (exec_cmd.out) |path| {
        publishBrowserResult(std.Io.Dir.cwd(), io, path, result.items) catch
            return browserExecuteError(stderr, "출력 파일을 원자적으로 게시할 수 없습니다");
        try stdout.print("executeScript: {d} bytes → {s}\n", .{ result.items.len, path });
    } else {
        try stdout.writeAll(result.items);
        try stdout.writeAll("\n");
    }
    try stdout.flush();
}

/// §9.5.10 통일: inline이 method-특화 wrapper(`{result:{<wrap_field>:value}}`)인 browser 메서드(snapshot·console)의 응답을
/// 스트리밍으로 받는다. 결과가 512 KiB 이하면 inline 단일 응답이라 그대로 renderResponse하고, 초과면 `chunk_method`
/// notification×N을 base64 재조립해 raw 값을 복원한 뒤 synthetic 응답 `{result:{<wrap_field>:value}}`로 감싸 렌더한다(대형
/// 결과가 프레임 상한을 넘던 결함 해소 — executeScript와 같은 transfer). 검증·재조립은 `WrappedResultStreamValidator`(L2 순수,
/// executeScript와 동형 bounded 검증). error 응답도 그대로 렌더. GUI 손 테스트로 대형 왕복 확인. `wrap_field`는 서버 잘못된
/// 스트림 에러 메시지 라벨도 겸한다.
fn runBrowserWrappedResult(
    io: std.Io,
    allocator: std.mem.Allocator,
    req: maru.cli.browser.Request,
    chunk_method: []const u8,
    wrap_field: []const u8,
    kind: maru.cli.browser.ResponseKind,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const max_bytes = switch (req) {
        .snapshot => maru.session.control_browser.snapshot_max_result_bytes,
        .console => maru.session.control_browser.console_max_result_bytes,
        else => unreachable, // 라우터가 snapshot·console만 이리로 보냄
    };
    const request_id: maru.session.control_plane.Id = .{ .number = 1 };
    const request_bytes = try maru.cli.browser.buildRequestBytes(allocator, req, request_id);
    defer allocator.free(request_bytes);
    const fd = try connectSendControl(io, allocator, request_bytes, stderr);
    defer _ = std.c.close(fd);

    var validator = maru.cli.browser.WrappedResultStreamValidator.init(allocator, request_id, chunk_method, max_bytes);
    var reassembled: std.ArrayList(u8) = .empty; // chunked면 재조립한 raw 값(트리/배열) JSON 바이트
    defer reassembled.deinit(allocator);
    var terminal_line: ?[]u8 = null; // inline/error 응답 그대로 렌더용(chunked면 null → synthetic)
    defer if (terminal_line) |l| allocator.free(l);
    var chunked = false;
    var framer: maru.session.control_plane.Framer = .{};
    defer framer.deinit(allocator);
    var decode_scratch: [512 * 1024]u8 = undefined;

    done: while (true) {
        while (framer.next() catch null) |line| {
            switch (validator.feed(line, &decode_scratch)) {
                .need_more => {},
                .chunk => |bytes| reassembled.appendSlice(allocator, bytes) catch return error.OutOfMemory,
                .inline_terminal => {
                    terminal_line = try allocator.dupe(u8, line); // inline `{<wrap_field>}` 또는 에러 — 그대로 렌더
                    break :done;
                },
                .done => {
                    chunked = true;
                    break :done;
                },
                .failed => return wrappedStreamError(stderr, wrap_field),
            }
        }
        var read_buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &read_buf, read_buf.len);
        if (n <= 0) return wrappedStreamError(stderr, wrap_field);
        framer.push(allocator, read_buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }

    if (chunked) {
        // 재조립한 raw 값을 synthetic 응답 `{result:{<wrap_field>:value}}`로 감싸 기존 렌더러 재사용(inline과 같은 렌더 경로).
        var synth: std.ArrayList(u8) = .empty;
        defer synth.deinit(allocator);
        synth.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"") catch return error.OutOfMemory;
        synth.appendSlice(allocator, wrap_field) catch return error.OutOfMemory;
        synth.appendSlice(allocator, "\":") catch return error.OutOfMemory;
        synth.appendSlice(allocator, reassembled.items) catch return error.OutOfMemory;
        synth.appendSlice(allocator, "}}") catch return error.OutOfMemory;
        try maru.cli.browser.renderResponse(allocator, synth.items, kind, stdout);
    } else if (terminal_line) |line| {
        try maru.cli.browser.renderResponse(allocator, line, kind, stdout);
    } else {
        return wrappedStreamError(stderr, wrap_field);
    }
    try stdout.flush();
}

fn wrappedStreamError(stderr: *std.Io.Writer, cmd_label: []const u8) error{UnknownCommand} {
    stderr.print("maru browser {s}: 서버가 잘못된 {s} stream을 반환했습니다\n", .{ cmd_label, cmd_label }) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

/// 결과 바이트가 완결 strict JSON인지 **메모리 슬라이스로** 검증한다(write-only spool read-back 회피). 깊이
/// 깊이 128 상한(중첩 폭발 DoS 방어). 빈 입력은 유효 JSON이 아니므로 false.
fn validateJsonSlice(allocator: std.mem.Allocator, bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.next() catch return false;
        if (scanner.stackHeight() > 128) return false;
        if (token == .end_of_document) return true;
    }
}

/// 검증된 결과를 `target`에 **0600 원자적으로** 공개한다(검증-전-미노출 보존). 임시 파일 핸들이 write-only여도(macOS)
/// 되읽지 않으므로 무방. `.replace=true`+`Atomic.replace`라 기존 target을 **덮어쓴다**(폴링/재실행 정상화 —
/// 옛 `.link` no-clobber 회귀 수정). caller가 에러를 사용자 메시지로 매핑.
fn publishBrowserResult(dir: std.Io.Dir, io: std.Io, target: []const u8, bytes: []const u8) !void {
    // **Windows에서는 도달할 수 없고, 도달해서도 안 된다.** 도달 불가인 이유: 이 경로는 컨트롤 소켓 왕복 뒤에만
    // 오는데 `connectSendControl`이 Windows에서 "인스턴스 없음"으로 접는다. 도달하면 안 되는 이유: POSIX의
    // `0o600`(소유자 전용)에 해당하는 것이 Windows에는 없고 — `Permissions`가 POSIX mode가 아니라 **ACL**을 나르는
    // `FILE.ATTRIBUTE` enum이라 `fromMode`가 아예 없다 — 무엇으로 대체할지가 아직 미결정이기 때문이다
    // (docs/windows-platform.md §8 "`publishBrowserResult`의 파일 권한": 부모 디렉터리 ACL 상속 vs 현재 사용자
    // SID만 허용하는 명시 ACL).
    //
    // 그래서 `.default_file`로 조용히 넘기지 않는다. 그것은 부모 폴더의 ACL을 물려받는다는 뜻이고, 이 파일은
    // 사용자가 `--out`으로 준 임의 경로라 공유 폴더·네트워크 드라이브면 보장이 사라진다. 컨트롤 플레인을
    // 이식하는 사람이 이 결정을 잊으면 **조용히 넓은 권한으로 쓰이는 대신 여기서 시끄럽게 실패**해야 한다.
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;

    var af = try dir.createFileAtomic(io, target, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .replace = true,
    });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
}

fn browserExecuteError(stderr: *std.Io.Writer, message: []const u8) error{UnknownCommand} {
    stderr.print("maru browser exec: {s}\n", .{message}) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

/// `maru browser screenshot`을 컨트롤 소켓에 왕복한다(§9.6·§9.5.7). 단일 응답이 아니라 **chunk 스트림**이라
/// `fetchControlResponse`(첫 응답만)와 달리 `connectSendControl`로 열고 프레임을 고정 scratch로 검증·decode해 메모리에
/// 누적한다. 최종 metadata와 PNG header까지 검증한 뒤에만 `publishBrowserResult`(원자적 `--out`) 또는 stdout으로 공개한다.
fn runBrowserScreenshot(
    io: std.Io,
    allocator: std.mem.Allocator,
    shot: maru.cli.browser.ScreenshotCmd,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const c = std.c;
    const request_bytes = try maru.cli.browser.buildScreenshotRequestBytes(allocator, shot, .{ .number = 1 });
    defer allocator.free(request_bytes);
    const fd = try connectSendControl(io, allocator, request_bytes, stderr);
    defer _ = c.close(fd);

    const request_id: maru.session.control_plane.Id = .{ .number = 1 };
    var validator = maru.cli.browser.ScreenshotStreamValidator.init(request_id);
    // PNG를 메모리에 누적(validator가 chunk 상한 강제). write-only spool read-back 회피(exec와 동일 이유).
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(allocator);
    var framer: maru.session.control_plane.Framer = .{};
    defer framer.deinit(allocator);
    var decode_scratch: [512 * 1024]u8 = undefined;
    done: while (true) {
        while (framer.next() catch null) |line| {
            switch (validator.feed(allocator, line, &decode_scratch) catch return error.OutOfMemory) {
                .need_more => {},
                .chunk => |bytes| {
                    result.appendSlice(allocator, bytes) catch return error.OutOfMemory;
                },
                .done => break :done,
                .error_response => {
                    // 서버가 정상 JSON-RPC error(unauthorized·surface 없음 등) 반환 — 일반 "잘못된 stream" 대신 실제
                    // code/message를 stderr에 내고 exit 1. renderResponse는 error 응답에서 kind를 안 쓴다(.ok는 표식일 뿐).
                    maru.cli.browser.renderResponse(allocator, line, .ok, stderr) catch {};
                    stderr.flush() catch {};
                    return error.UnknownCommand;
                },
                .failed => return browserScreenshotError(stderr, "서버가 잘못된 screenshot stream을 반환했습니다"),
            }
        }
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len); // grant held면 사용자 클릭까지 블록(§9.6)
        if (n <= 0) return browserScreenshotError(stderr, "서버가 응답을 끝내지 않았습니다 (불완전한 스트림)");
        framer.push(allocator, buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }

    if (shot.out) |path| {
        publishBrowserResult(std.Io.Dir.cwd(), io, path, result.items) catch
            return browserScreenshotError(stderr, "출력 파일을 원자적으로 게시할 수 없습니다");
        try stdout.print("screenshot: {d}x{d} PNG, {d} bytes → {s}\n", .{ validator.width, validator.height, result.items.len, path });
        try stdout.flush();
    } else {
        try stdout.writeAll(result.items);
        try stdout.flush();
    }
}

/// screenshot 실패(재조립 오류·서버 에러·불완전 스트림)를 stderr에 내고 graceful exit 1 sentinel을 돌려준다(sessionNoInstance 동형).
fn browserScreenshotError(stderr: *std.Io.Writer, msg: []const u8) error{UnknownCommand} {
    stderr.print("maru browser screenshot: {s}\n", .{msg}) catch {};
    stderr.flush() catch {};
    return error.UnknownCommand;
}

/// **컨트롤 소켓 발견→connect→auth→요청 전송(sessions/browser/screenshot CLI 공유)**: 결정론 경로(§4.2)에서 살아있는
/// 인스턴스 소켓 하나를 찾아 connect → `auth.self`(selector=`MARU_PANE_ID`·cap_nonce=null) → `request_bytes` 전송까지 한다.
/// 성공 시 **열린 fd**를 반환한다 — caller가 응답/chunk를 읽고 **close**한다(단일 응답=`fetchControlResponse`, chunk
/// 스트림=screenshot). 인스턴스 없음/connect 실패는 `sessionNoInstance`(graceful exit 1); 에러 반환 전 이미 만든 fd는
/// `errdefer`로 닫는다(성공 반환 시엔 caller 소유). 순수 정책(경로·발견 판정)은 `cli.sessions`, 여긴 getenv/readdir/소켓
/// syscall 접착만(§11 L4).
fn connectSendControl(io: std.Io, allocator: std.mem.Allocator, request_bytes: []const u8, stderr: *std.Io.Writer) !std.c.fd_t {
    // Windows에는 이 transport가 아직 없다(백로그 — 계약 §8 "컨트롤 플레인 transport"). **인스턴스 없음으로
    // 접는다**: 그것이 이미 있는 graceful 경로이고(소켓 디렉터리가 없을 때와 같은 결과), CLI가 crash 대신
    // exit 1로 끝난다. 이 early return은 comptime 참이라 아래 POSIX 본문이 **의미 분석조차 되지 않아**
    // `c.socket`이 undefined symbol이 되지 않는다(실측 확인) — 이것이 named pipe 이식 없이 빌드를 뚫는 방법이다.
    if (gate_control_socket) |reason|
        return sessionNoInstance(stderr, reason);

    const c = std.c;
    const posix = std.posix;

    // ── 소켓 발견: 결정론 경로 <cache>/maru/control에서 살아있는 인스턴스 소켓 하나를 찾는다(§4.2) ──
    const home_z = c.getenv("HOME") orelse
        return sessionNoInstance(stderr, "HOME 환경변수가 없어 컨트롤 소켓 위치를 정할 수 없습니다");
    const xdg: ?[]const u8 = if (c.getenv("XDG_CACHE_HOME")) |x| std.mem.span(x) else null;
    const control_dir = try maru.cli.sessions.controlDir(allocator, xdg, std.mem.span(home_z));
    defer allocator.free(control_dir);

    // control dir을 열어 `.sock` 엔트리 이름을 모은다(못 열면 = 인스턴스 없음). readdir는 L4 I/O라 여기(main)서 한다.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    {
        var dir = std.Io.Dir.cwd().openDir(io, control_dir, .{ .iterate = true }) catch
            return sessionNoInstance(stderr, null);
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            // kind로 거르지 않는다 — 소켓 파일의 dir 엔트리 kind는 `.unix_domain_socket`(≠`.file`)이라 `.file`만
            // 받으면 소켓을 놓친다. `.sock` 접미사로만 거르고(같은 dir의 `<key>.lock`은 제외), 최종 판정은 pickSocket이 한다.
            if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.name)); // entry.name은 iterator 버퍼(transient) → 복사
        }
    }

    // 발견 정책은 순수(1d pickSocket): 정확히 하나면 그 소켓, 없으면/여럿이면 graceful.
    const chosen = switch (maru.cli.sessions.pickSocket(names.items)) {
        .none => return sessionNoInstance(stderr, null),
        .multiple => return sessionNoInstance(stderr, "여러 maru 인스턴스가 있습니다 — 인스턴스 선택은 아직 지원되지 않습니다"),
        .single => |name| name,
    };
    const socket_path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ control_dir, chosen }, 0);
    defer allocator.free(socket_path);

    // ── connect(L4 syscall — 1b가 std.c로 소켓을 쓰는 선례) ──
    const fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd < 0) return sessionNoInstance(stderr, "소켓을 만들 수 없습니다");
    errdefer _ = c.close(fd); // 에러 반환 시 닫는다 — 성공 반환(return fd) 시엔 caller가 소유·close
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= addr.path.len) return sessionNoInstance(stderr, null); // 경로가 sun_path 초과(비정상) → graceful
    @memcpy(addr.path[0..socket_path.len], socket_path);
    // 서버 부재(ENOENT)·stale 소켓(ECONNREFUSED) 등은 전부 graceful "인스턴스 없음"으로 접는다(crash·트레이스 금지).
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
        return sessionNoInstance(stderr, null);

    // ── A2b auth 셀렉터 전송(§8.4 1단계): caller가 자기 surface를 주장한다. maru 팬 셸엔 MARU_PANE_ID=<surface.id>가
    // 주입돼 있으므로(pty/macos appendParentEnv) 그 값을 self 셀렉터로 보낸다. maru 밖 shell엔 없어 null. cap_nonce=null:
    // CLI는 상속 capability fd(§8.5)를 안 읽는다 — browser 요청은 세션 cap 없이 §9.2 Model B needs_grant→확인 모달로 인가받는다. ──
    const selector: ?u64 = if (c.getenv("MARU_PANE_ID")) |pane|
        (std.fmt.parseInt(u64, std.mem.span(pane), 10) catch null)
    else
        null;
    const auth_bytes = try maru.session.control_plane.serializeAuthSelf(allocator, selector, null);
    defer allocator.free(auth_bytes);
    if (!writeAllFd(fd, auth_bytes) or !writeAllFd(fd, "\n"))
        return sessionNoInstance(stderr, "auth 셀렉터 전송에 실패했습니다");

    // ── 요청 전송(응답/chunk 읽기는 caller) ──
    if (!writeAllFd(fd, request_bytes) or !writeAllFd(fd, "\n"))
        return sessionNoInstance(stderr, "요청 전송에 실패했습니다");
    return fd; // 성공 — caller가 읽고 close(errdefer 미발동)
}

/// **단일 응답 소켓 왕복(sessions/browser 단일-응답 CLI 공유)**: `connectSendControl`로 열고 hello notification skip 후
/// **첫 응답 프레임**을 alloc 소유 슬라이스로 반환(caller free·자기 kind로 render). EOF는 `sessionNoInstance`(graceful).
/// browser 요청은 grant 모달로 held될 수 있어 read가 오래 블록될 수 있다(짧은 타임아웃 금지 — §9.6).
fn fetchControlResponse(io: std.Io, allocator: std.mem.Allocator, request_bytes: []const u8, stderr: *std.Io.Writer) ![]u8 {
    const c = std.c;
    const fd = try connectSendControl(io, allocator, request_bytes, stderr);
    defer _ = c.close(fd);

    var framer: maru.session.control_plane.Framer = .{};
    defer framer.deinit(allocator);
    while (true) {
        // 완결 프레임을 소비한다: hello(notification)는 서버가 accept 시 먼저 보내므로 skip, 그 밖(응답)이면 반환.
        while (framer.next() catch null) |line| {
            var pm = maru.session.control_plane.parseMessage(allocator, line) catch
                return allocator.dupe(u8, line); // 손상 응답도 caller renderResponse가 안전하게 접는다
            const is_notification = pm.message == .notification;
            pm.deinit();
            if (is_notification) continue; // hello notification skip
            return allocator.dupe(u8, line); // 첫 응답(line은 framer 버퍼라 반환 전 복사)
        }
        var buf: [4096]u8 = undefined;
        const n = c.read(fd, &buf, buf.len); // browser grant held면 사용자 클릭까지 블록(§9.6)
        if (n <= 0) break; // EOF/에러 — 응답 없이 종료(grant 무응답 timeout 서버 reap 포함)
        framer.push(allocator, buf[0..@intCast(n)]) catch return error.OutOfMemory;
    }
    return sessionNoInstance(stderr, "서버가 응답하지 않았습니다");
}

/// 부분 write를 처리하는 blocking write-all(소켓 stream). 성공하면 true. main의 얇은 소켓 접착 편의(control_socket의
/// writeAll과 같은 결이지만 그 파일은 dev-CLI 모듈 밖이라 여기 둔다).
fn writeAllFd(fd: std.c.fd_t, bytes: []const u8) bool {
    const c = std.c;
    const posix = std.posix;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) {
            if (posix.errno(n) == .INTR) continue;
            return false;
        }
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// 살아있는 maru 인스턴스가 없거나 connect가 실패했을 때의 graceful 종료. stderr에 안내를 쓰고 `error.UnknownCommand`
/// (main이 트레이스 없이 exit 1로 접는 sentinel)를 돌려준다 — 사용자 오타/부재에 crash처럼 보이지 않게. `detail`은
/// 있으면 괄호로 덧붙인다.
fn sessionNoInstance(stderr: *std.Io.Writer, detail: ?[]const u8) error{UnknownCommand} {
    stderr.writeAll("실행 중인 maru 인스턴스를 찾지 못했습니다") catch {};
    if (detail) |d| stderr.print(" ({s})", .{d}) catch {};
    stderr.writeAll(".\n") catch {};
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

// 이 테스트는 **POSIX 파일 모드가 있는 호스트**의 것이다. Windows에는 `0o600`에 해당하는 것이 없고
// (`Permissions`가 mode가 아니라 ACL을 나르는 `FILE.ATTRIBUTE` enum이라 `toMode`가 없다), 무엇으로 대체할지가
// 미결정이라 `publishBrowserResult` 자체가 거기서 `error.UnsupportedOnWindows`로 막혀 있다
// (docs/windows-platform.md §8). **OS 이름이 아니라 없는 전제 그 자체로 skip한다** — `Permissions`에 `toMode`가
// 생기는 날 저절로 깨어나야 한다(`connection_incident`의 `currentProcessId() == 0` skip과 같은 규율,
// docs/layering-and-portability.md §4.1).
test "publishBrowserResult: 0600 원자 공개 + 기존 파일 덮어쓰기(폴링 재실행 정상화)" {
    if (!@hasDecl(std.Io.File.Permissions, "toMode")) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try publishBrowserResult(tmp.dir, io, "result.bin", "first");
    const stat = try tmp.dir.statFile(io, "result.bin", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    // 같은 경로에 재공개 = **덮어쓰기 성공**(옛 no-clobber 회귀 수정). 내용은 최신("second").
    try publishBrowserResult(tmp.dir, io, "result.bin", "second");
    var buf: [6]u8 = undefined;
    const file = try tmp.dir.openFile(io, "result.bin", .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings("second", buf[0..n]);
}
