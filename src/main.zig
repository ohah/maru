const std = @import("std");
const maru = @import("maru");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

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

fn runSsh(allocator: std.mem.Allocator, args: anytype, stderr: *std.Io.Writer) !void {
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

    const argv = try maru.cli.ssh.buildArgv(allocator, parsed);
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
    const dir = try maru.terminfo_cache.cacheDirZ(allocator, std.mem.span(home_z));
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
        \\
    );
    try writer.flush();
}

test "development CLI imports maru module" {
    try std.testing.expectEqual(@as(u16, 80), maru.terminal.Size.default.cols);
}
