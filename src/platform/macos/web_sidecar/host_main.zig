//! `maru-web-host` — CEF 브라우저 프로세스(W1b, docs/plans/web-osr-backend.md C1·C2).
//!
//! maru 가 `maru-web-host --profile-dir=<절대 경로>` 로 띄운다. 흐름:
//! ① stdin/stdout 을 프로토콜 전용으로 떼어 낸다(`stdio.zig`) ② 첫 frame `hello` 를 받아 같은 값으로 `hello_ack`
//! ③ 프레임워크를 dlopen 하고 CEF 를 초기화한다 ④ 읽기 스레드가 명령을 받아 UI 스레드에 넘긴다(`inbox.zig`)
//! ⑤ `shutdown` 또는 stdin EOF(maru 가 사라졌다)면 메시지 루프를 끝내고 CEF 를 내린다.
//! `failure.detail`·stderr 문구는 **진단용 영어**다 — 사용자에게 보일 문구는 maru 가 `failure.code` 로 i18n 해서 만든다(W3).
//! 프로세스는 샌드박스 밖이다 — 신뢰할 수 없는 웹은 샌드박스 안 helper 가 그린다(`helper_main.zig`).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const cef = @import("cef.zig");
const c = cef.c;
const object = @import("object.zig");
const library = @import("library.zig");
const layout = @import("layout.zig");
const stdio = @import("stdio.zig");
const events = @import("events.zig");
const inbox_mod = @import("inbox.zig");
const dispatch = @import("dispatch.zig");
const app = @import("app.zig");
const settings_mod = @import("settings.zig");
const profile = @import("profile.zig");
const browsers = @import("browsers.zig");
const preferences = @import("preferences.zig");
const watchdog = @import("watchdog.zig");

/// 종료 코드. maru 는 이 값으로 알림을 못 받은 실패(채널이 없거나 닫힌 뒤)를 가른다.
pub const ExitCode = enum(u8) {
    ok = 0,
    stdio_unavailable = 10,
    handshake_failed = 11,
    bad_arguments = 12,
    framework_unavailable = 13,
    cef_initialize_failed = 14,
    reader_thread_failed = 15,
    /// 같은 프로필을 다른 sidecar 가 쥐고 있다(CEF process singleton — exit code 24 로 알려 온다).
    profile_in_use = 16,
    /// 종료를 시작하고 `watchdog.deadline_ms` 안에 못 끝냈다 — 감시견이 끝냈다.
    shutdown_stuck = watchdog.exit_code,
};

// CEF 콜백·읽기 스레드가 닿아야 해서 전역이다(프로세스에 하나).
var g_api: library.Api = undefined;
var g_inbox: inbox_mod.Inbox = undefined;
var g_writer: events.Writer = undefined;
var g_dispatcher: dispatch.Dispatcher = undefined;
var g_task: c.cef_task_t = undefined;

pub fn main(init: std.process.Init) u8 {
    return @intFromEnum(run(init));
}

/// 메시지 루프가 도는 동안만 읽기 스레드가 task 를 올린다 — `cef_shutdown` 도중·뒤에 올리지 않게.
var g_accepting = std.atomic.Value(bool).init(true);

fn run(init: std.process.Init) ExitCode {
    // 부모는 가장 먼저 기록한다 — 채널을 떼는 사이 부모가 죽어 launchd 로 입양되면 1 이 나온다(읽기 스레드가 곧 끝낸다).
    const parent = std.c.getppid();
    const channels = stdio.take() catch return .stdio_unavailable;
    // stdout 표지: 보호가 제대로면 이 줄은 stderr 로 간다. 보호가 깨지면 알림 채널을 더럽혀 판정자의 첫 frame 이 깨진다 —
    // Chromium 이 stdout 에 아무것도 안 찍어(실측) 판정자의 「stdout 에는 frame 만」 검사가 빈 검사였던 것을 채운다.
    const sentinel = "maru-web-host: stdio ready\n";
    _ = std.c.write(1, sentinel.ptr, sentinel.len);
    g_writer = .{ .fd = channels.events };
    g_dispatcher = .{ .writer = &g_writer, .handler = browsers.handler() };

    const hello = g_dispatcher.readHello(channels.commands) catch return .handshake_failed;
    g_writer.send(.{ .hello_ack = hello }) catch return .handshake_failed;

    const argv = init.minimal.args.vector;
    const profile_dir = profileDir(argv) orelse return fail(.bad_arguments, .cef_initialize_failed, "missing --profile-dir=<absolute path>");
    profile.ensurePrivateDir(profile_dir) catch |err| return fail(.bad_arguments, .cef_initialize_failed, switch (err) {
        error.NotPrivate => "profile directory is a symlink, not ours, or readable by other users",
        error.MkdirFailed => "cannot create the profile directory",
    });
    if (!profile.excludeFromBackup(profile_dir)) std.debug.print("maru-web-host: cannot exclude the profile from backups\n", .{});

    var dir_buf: layout.PathBuf = undefined;
    const install_dir = layout.executableDir(&dir_buf) catch return fail(.framework_unavailable, .cef_initialize_failed, "cannot resolve the executable path");
    var framework_buf: layout.PathBuf = undefined;
    const framework = layout.join(&framework_buf, install_dir, layout.framework_dir_name ++ "/" ++ layout.framework_binary_name) catch
        return fail(.framework_unavailable, .cef_initialize_failed, "path too long");
    g_api = library.load(framework) catch return fail(.framework_unavailable, .cef_initialize_failed, "cannot open the CEF framework");
    _ = g_api.api_hash(cef.api_version, 0);

    var settings = settings_mod.build(&g_api, .{ .install_dir = install_dir, .profile_dir = profile_dir }) catch
        return fail(.bad_arguments, .cef_initialize_failed, "path too long");
    var main_args: c.cef_main_args_t = .{ .argc = @intCast(argv.len), .argv = @ptrCast(@constCast(argv.ptr)) };
    browsers.init(&g_api, &g_writer);
    if (g_api.initialize(&main_args, &settings, app.get(&g_api), null) == 0) {
        if (g_api.get_exit_code() == c.CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED) {
            return fail(.profile_in_use, .profile_in_use, "profile is in use by another process");
        }
        return fail(.cef_initialize_failed, .cef_initialize_failed, "cef_initialize failed");
    }
    // 브라우저를 만들기 전에 — 명령은 메시지 루프가 돌아야 처리된다.
    const unset = preferences.apply(&g_api);
    if (unset != 0) std.debug.print("maru-web-host: {d} product preference(s) not applied\n", .{unset});

    g_inbox = .{ .io = init.io };
    g_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&g_task.base);
    g_task.execute = &drainTask;
    const reader = std.Thread.spawn(.{}, readThenWatch, .{ channels.commands, parent }) catch {
        g_api.shutdown();
        return fail(.reader_thread_failed, .cef_initialize_failed, "cannot start the command reader thread");
    };
    // 스레드는 fd 가 닫힐 때까지 막혀 있다 — 프로세스가 끝나며 함께 사라진다.
    reader.detach();
    // hello 와 한 읽기에 딸려 온 명령이 decoder 에 남아 있을 수 있다 — 루프 첫 task 로 처리한다.
    wakeUiThread();

    g_api.run_message_loop();
    g_accepting.store(false, .release);
    g_api.shutdown();
    return .ok;
}

/// 읽기 스레드 본문. 채널이 끝나면(EOF·부모 종료) 감시견을 켠다 — UI 스레드가 멈춰 있어 종료 task 를 못 돌려도
/// 프로세스가 남지 않게.
fn readThenWatch(fd: c_int, parent: c_int) void {
    inbox_mod.readLoop(fd, &g_inbox, &wakeUiThread, parent);
    watchdog.start();
}

/// 읽기 스레드에서 부른다 — CEF UI 스레드에 상자를 비우는 task 를 올린다.
fn wakeUiThread() void {
    if (!g_accepting.load(.acquire)) return;
    _ = g_api.post_task(c.TID_UI, &g_task);
}

fn drainTask(_: [*c]c.cef_task_t) callconv(.c) void {
    // 열린 브라우저를 모두 닫은 뒤에 루프를 끝낸다(browsers.beginShutdown).
    if (g_dispatcher.drain(&g_inbox) == .quit) browsers.beginShutdown();
}

/// 알릴 수 있으면 알리고 종료 코드를 돌려준다.
fn fail(code: ExitCode, failure: protocol.message.FailureCode, detail: []const u8) ExitCode {
    g_writer.send(.{ .failure = .{ .browser = 0, .code = failure, .detail = detail } }) catch {};
    return code;
}

fn profileDir(argv: []const [*:0]const u8) ?[:0]const u8 {
    const prefix = "--profile-dir=";
    for (argv[1..]) |raw| {
        const arg = std.mem.span(raw);
        if (std.mem.startsWith(u8, arg, prefix)) {
            const value = arg[prefix.len..];
            if (value.len == 0 or value[0] != '/') return null;
            return value;
        }
    }
    return null;
}
