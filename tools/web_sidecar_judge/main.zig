//! 웹 OSR sidecar W1b·W1c 판정자 — `maru-web-judge <설치 디렉터리> <프로필 뿌리>`.
//!
//! 실제 `maru-web-host` 를 maru 처럼 띄워 docs/plans/web-osr-backend.md 「W1b」 완료 판정을 잰다:
//!   handshake        hello → 같은 instance·nonce 의 hello_ack
//!   version-mismatch 다른 제어 채널 버전의 hello → 제 버전의 hello_ack(0·0) 하나와 exit 18(W7a1 —
//!                    따로 설치된 maru 와 `maru-chromium` 이 어긋나면 maru 는 이 머리로 「버전 불일치」를 알아본다)
//!   helper-sandbox   host 의 자식이 모두 `maru-web-helper` 이고 `sandbox_check` 1(host 자신은 샌드박스 밖)
//!   shutdown-clean   shutdown → 알림이 끝까지 frame 으로만 풀리고(stdout 오염 없음) exit 0, helper 도 사라진다
//!   parent-death     maru 역할 프로세스를 SIGKILL 하면 host 와 helper 가 모두 사라진다(고아 Chromium 없음) — 명령 pipe 의
//!                    쓰기 끝을 손자(maru 가 띄운 셸 흉내)가 쥐고 있어 EOF 가 오지 않아도
//!   no-crash         판정 동안 `maru-web-*` 크래시 보고가 하나도 새로 생기지 않는다
//! W1c 판정은 `browsers_check.zig`, W2 판정은 `frames_check.zig`, W4 입력 판정은 `input_check.zig`, W5a 대화상자·파일 선택
//! 판정은 `dialogs_check.zig`, W5b 권한 판정은 `permissions_check.zig` 가 든다. 하나라도 틀리면 exit 1.
//! `maru-web-judge --input <설치 디렉터리> <프로필 뿌리>` 는 입력 판정만, `--dialogs` 는 대화상자 판정만, `--permissions` 는 권한
//! 판정만 돈다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const sandbox = @import("sandbox.zig");
const http = @import("http.zig");
const browsers_check = @import("browsers_check.zig");
const frames_check = @import("frames_check.zig");
const input_check = @import("input_check.zig");
const dialogs_check = @import("dialogs_check.zig");
const permissions_check = @import("permissions_check.zig");
const popup_check = @import("popup_check.zig");
const tooltip_check = @import("tooltip_check.zig");
const contextmenu_check = @import("contextmenu_check.zig");
const drag_check = @import("drag_check.zig");
const newtab_check = @import("newtab_check.zig");
const attacks = @import("attacks.zig");

const helper_wait_ms = 20_000;
const exit_wait_ms = 20_000;
/// 알림 하나를 기다리는 상한 — 초기화 직후의 답도 이 안에 온다.
const reply_wait_ms = 15_000;

var failures: u32 = 0;

extern "c" fn signal(sig: c_int, handler: usize) usize;

fn report(ok: bool, name: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!ok) failures += 1;
    std.debug.print("{s} {s}: " ++ fmt ++ "\n", .{ if (ok) "PASS" else "FAIL", name } ++ args);
}

fn reportText(ok: bool, name: []const u8, detail: []const u8) void {
    report(ok, name, "{s}", .{detail});
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--rogue")) return frames_check.rogueMain(std.mem.span(argv[2]), std.mem.span(argv[3]));
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--attack")) return attacks.main(std.mem.span(argv[2]), std.mem.span(argv[3]));
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--input")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        var profile_buf: [1024]u8 = undefined;
        const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/e", .{std.mem.span(argv[3])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        inputChecks(host, profile);
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--dialogs")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        dialogChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--popup")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        popupChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--drag")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        dragChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--newtab")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        newTabChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--contextmenu")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        contextMenuChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--tooltip")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        tooltipChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len == 4 and std.mem.eql(u8, std.mem.span(argv[1]), "--permissions")) {
        _ = signal(13, 1);
        var host_buf: [1024]u8 = undefined;
        const host = std.fmt.bufPrintZ(&host_buf, "{s}/maru-web-host", .{std.mem.span(argv[2])}) catch return 2;
        warmUp(host, std.mem.span(argv[3]));
        permissionChecks(host, std.mem.span(argv[3]));
        return if (failures == 0) 0 else 1;
    }
    if (argv.len != 3) {
        std.debug.print("사용: maru-web-judge <설치 디렉터리> <프로필 뿌리>\n", .{});
        return 2;
    }
    // 판정자 자신이 닫힌 파이프에 써도 신호로 죽지 않고 실패로 보고하게 한다.
    _ = signal(13, 1);
    const started_at = os.unixNow();
    const install_dir = std.mem.span(argv[1]);
    const profile_root = std.mem.span(argv[2]);

    var host_path_buf: [1024]u8 = undefined;
    const host_path = std.fmt.bufPrintZ(&host_path_buf, "{s}/maru-web-host", .{install_dir}) catch return 2;
    var profile_a_buf: [1024]u8 = undefined;
    const profile_a = std.fmt.bufPrintZ(&profile_a_buf, "--profile-dir={s}/a", .{profile_root}) catch return 2;
    var profile_b_buf: [1024]u8 = undefined;
    const profile_b = std.fmt.bufPrintZ(&profile_b_buf, "--profile-dir={s}/b", .{profile_root}) catch return 2;

    sessionChecks(host_path, profile_a) catch |err| report(false, "session", "{s}", .{@errorName(err)});
    versionMismatch(host_path, profile_a) catch |err| report(false, "version-mismatch", "{s}", .{@errorName(err)});
    var profile_c_dir_buf: [1024]u8 = undefined;
    const profile_c_dir = std.fmt.bufPrintZ(&profile_c_dir_buf, "{s}/c", .{profile_root}) catch return 2;
    var profile_c_buf: [1024]u8 = undefined;
    const profile_c = std.fmt.bufPrintZ(&profile_c_buf, "--profile-dir={s}", .{profile_c_dir}) catch return 2;
    if (http.Server.start()) |server| {
        browsers_check.run(&reportText, host_path, profile_c_dir, profile_c, server.port) catch |err| report(false, "browsers", "{s}", .{@errorName(err)});
        var profile_d_buf: [1024]u8 = undefined;
        const profile_d = std.fmt.bufPrintZ(&profile_d_buf, "--profile-dir={s}/d", .{profile_root}) catch return 2;
        var frames_log_buf: [1024]u8 = undefined;
        const frames_log = std.fmt.bufPrintZ(&frames_log_buf, "{s}/frames-host.log", .{profile_root}) catch return 2;
        frames_check.run(&reportText, argv[0], host_path, profile_d, frames_log, server.port) catch |err| report(false, "frames", "{s}", .{@errorName(err)});
    } else |err| report(false, "browsers", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_e_buf: [1024]u8 = undefined;
    const profile_e = std.fmt.bufPrintZ(&profile_e_buf, "--profile-dir={s}/e", .{profile_root}) catch return 2;
    inputChecks(host_path, profile_e);
    dialogChecks(host_path, profile_root);
    permissionChecks(host_path, profile_root);
    popupChecks(host_path, profile_root);
    tooltipChecks(host_path, profile_root);
    contextMenuChecks(host_path, profile_root);
    dragChecks(host_path, profile_root);
    newTabChecks(host_path, profile_root);
    parentDeath(host_path, profile_b) catch |err| report(false, "parent-death", "{s}", .{@errorName(err)});

    // 크래시 보고는 ReportCrash 가 몇 초 늦게 쓴다.
    os.sleepMs(5000);
    var helper_path_buf: [1024]u8 = undefined;
    const helper_path = std.fmt.bufPrintZ(&helper_path_buf, "{s}/maru-web-helper", .{install_dir}) catch return 2;
    var host_uuid: [36]u8 = undefined;
    var helper_uuid: [36]u8 = undefined;
    if (os.machoUuid(host_path, &host_uuid)) |host_id| {
        if (os.machoUuid(helper_path, &helper_uuid)) |helper_id| {
            const crashes = os.crashReportsSince(started_at, &.{ host_id, helper_id });
            report(crashes == 0, "no-crash", "이 빌드(host {s} · helper {s})의 새 크래시 보고 {d} 개", .{ host_id[0..8], helper_id[0..8], crashes });
        } else report(false, "no-crash", "helper UUID 를 못 읽음", .{});
    } else report(false, "no-crash", "host UUID 를 못 읽음", .{});

    std.debug.print("{s}: 틀림 {d} 건\n", .{ if (failures == 0) "통과" else "실패", failures });
    return if (failures == 0) 0 else 1;
}

fn versionMismatch(host_path: [:0]const u8, profile: [:0]const u8) !void {
    var host = try Host.spawn(host_path, profile);
    defer {
        _ = std.c.close(host.commands);
        _ = std.c.close(host.events);
    }
    // 머리의 버전만 다른 hello(다음 버전의 maru 흉내).
    var buf: [64]u8 = undefined;
    const len = try protocol.codec.encode(.{ .hello = .{ .instance = 7, .nonce = 9 } }, &buf);
    std.mem.writeInt(u16, buf[protocol.wire.prefix_len + protocol.wire.magic.len ..][0..2], protocol.wire.version + 1, .big);
    if (std.c.write(host.commands, &buf, len) != @as(isize, @intCast(len))) return error.WriteFailed;
    const reply = host.next(reply_wait_ms) catch null;
    const acked = reply != null and reply.? == .hello_ack and reply.?.hello_ack.instance == 0 and reply.?.hello_ack.nonce == 0;
    const code = host.wait(exit_wait_ms);
    report(acked and code == 18, "version-mismatch", "제 버전 hello_ack(0·0) {} · exit {?d}(18 이어야)", .{ acked, code });
}

fn handshake(host: *Host) !void {
    const hello: protocol.message.Hello = .{ .instance = @intCast(std.c.getpid()), .nonce = os.random64() };
    try host.send(.{ .hello = hello });
    const reply = (try host.next(reply_wait_ms)) orelse return error.ClosedBeforeAck;
    const ok = reply == .hello_ack and reply.hello_ack.instance == hello.instance and reply.hello_ack.nonce == hello.nonce;
    report(ok, "handshake", "nonce {x}", .{hello.nonce});
    if (!ok) return error.HandshakeMismatch;
}

/// helper 가 적어도 `min` 개 뜰 때까지 기다린다(GPU·네트워크 유틸리티는 초기화 직후 뜬다).
fn waitForHelpers(host_pid: c_int, out: []c_int, min: usize) []c_int {
    var waited: u32 = 0;
    while (waited < helper_wait_ms) : (waited += 200) {
        const kids = os.children(host_pid, out);
        if (kids.len >= min) return kids;
        os.sleepMs(200);
    }
    return os.children(host_pid, out);
}

fn sessionChecks(host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    var host = try Host.spawn(host_path, profile_arg);
    try handshake(&host);

    var kids_buf: [64]c_int = undefined;
    const kids = waitForHelpers(host.pid, &kids_buf, 2);
    const state = sandbox.settle(host.pid, 2, helper_wait_ms);
    const host_outside = os.sandbox_check(host.pid, null, 0) == 0;
    report(state.all(2) and host_outside, "helper-sandbox", "helper {d} 개 · 샌드박스 {d} · 이름 일치 {d} · host 샌드박스 밖 {}", .{ state.total, state.sandboxed, state.named, host_outside });

    var remembered: [64]c_int = undefined;
    const remembered_len = os.children(host.pid, &remembered).len;
    _ = kids;
    try host.send(.shutdown);
    var extra: usize = 0;
    while (try host.next(exit_wait_ms)) |_| extra += 1;
    const code = host.wait(exit_wait_ms);
    const gone = allGone(remembered[0..remembered_len], exit_wait_ms);
    report(host.clean and extra == 0 and code != null and code.? == 0 and gone, "shutdown-clean", "stdout frame 만 {} · 남은 알림 {d} · exit {?d} · helper 모두 사라짐 {}", .{ host.clean, extra, code, gone });
}

/// maru 역할의 중간 프로세스가 host 를 띄우고 handshake 한 뒤 host pid 를 알려 온다. 그 프로세스를 SIGKILL 한다.
fn parentDeath(host_path: [:0]const u8, profile_arg: [:0]const u8) !void {
    var report_pipe: [2]c_int = undefined;
    if (std.c.pipe(&report_pipe) != 0) return error.PipeFailed;
    const parent = os.fork();
    if (parent < 0) return error.ForkFailed;
    if (parent == 0) {
        _ = std.c.close(report_pipe[0]);
        var host = Host.spawn(host_path, profile_arg) catch std.c._exit(3);
        const hello: protocol.message.Hello = .{ .instance = 1, .nonce = os.random64() };
        host.send(.{ .hello = hello }) catch std.c._exit(4);
        _ = (host.next(reply_wait_ms) catch std.c._exit(5)) orelse std.c._exit(6);
        // maru 가 띄운 셸처럼 명령 pipe 의 쓰기 끝을 물려받은 손자 — 부모가 죽어도 이것이 살아 있으면 EOF 가 오지 않는다.
        const grandchild = os.fork();
        if (grandchild == 0) {
            while (true) os.sleepMs(1000);
        }
        const pids = [2]c_int{ host.pid, grandchild };
        const pid_bytes = std.mem.asBytes(&pids);
        _ = std.c.write(report_pipe[1], pid_bytes.ptr, pid_bytes.len);
        while (true) os.sleepMs(1000);
    }
    _ = std.c.close(report_pipe[1]);
    var pids: [2]c_int = undefined;
    if (std.c.read(report_pipe[0], std.mem.asBytes(&pids).ptr, @sizeOf([2]c_int)) != @sizeOf([2]c_int)) return error.NoHostPid;
    const host_pid = pids[0];
    const grandchild = pids[1];
    defer _ = std.c.kill(grandchild, .KILL);

    var kids_buf: [64]c_int = undefined;
    const kids = waitForHelpers(host_pid, &kids_buf, 2);
    var watched: [65]c_int = undefined;
    watched[0] = host_pid;
    @memcpy(watched[1..][0..kids.len], kids);

    _ = std.c.kill(parent, .KILL);
    _ = std.c.waitpid(parent, null, 0);
    const gone = allGone(watched[0 .. kids.len + 1], exit_wait_ms);
    report(kids.len >= 2 and gone, "parent-death", "helper {d} 개 · 부모 SIGKILL 뒤 host·helper 모두 사라짐 {}", .{ kids.len, gone });
    if (!gone) for (watched[0 .. kids.len + 1]) |pid| {
        if (os.alive(pid)) _ = std.c.kill(pid, .KILL);
    };
}

fn allGone(pids: []const c_int, timeout_ms: u32) bool {
    return os.survivors(pids, timeout_ms) == 0;
}

/// 대화상자·파일 선택 판정(W5a) — 프로필은 `<뿌리>/f`, 고를 파일은 뿌리 아래에 만든다.
fn dialogChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "dialogs", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/f", .{profile_root}) catch return report(false, "dialogs", "프로필 경로가 길다", .{});
    dialogs_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "dialogs", "{s}", .{@errorName(err)});
}

/// 권한 판정(W5b) — 프로필은 `<뿌리>/g`(다시 띄워 기억을 잰다 — 같은 HTTP 서버라 출처가 같다).
fn permissionChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "permissions", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/g", .{profile_root}) catch return report(false, "permissions", "프로필 경로가 길다", .{});
    permissions_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "permissions", "{s}", .{@errorName(err)});
    var orphan_buf: [1024]u8 = undefined;
    const orphan_profile = std.fmt.bufPrintZ(&orphan_buf, "--profile-dir={s}/h", .{profile_root}) catch return report(false, "perm-camera-orphan", "프로필 경로가 길다", .{});
    permissions_check.cameraOrphan(&reportText, host_path, orphan_profile, server.port) catch |err| report(false, "perm-camera-orphan", "{s}", .{@errorName(err)});
}

/// 단독 모드의 첫 판정 전에 host 를 한 번 띄워 빈 브라우저를 만들고 끝낸다(프로필 `<뿌리>/w`) — 판정이 아니다. 새로 빌드한
/// x86_64 설치물의 첫 실행은 Rosetta 번역으로 느려 첫 페이지 준비가 15 초를 넘겼다(W6a① 실측 27 초, 다음부터 6~7 초).
/// 전체 판정은 앞의 판정들이 이 비용을 치른다. 걸린 시간을 출력해 정말 느려진 것은 보이게 한다(W6a① 적대 검증 5 차).
fn warmUp(host_path: [:0]const u8, profile_root: []const u8) void {
    const started = os.nowMs();
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/w", .{profile_root}) catch return;
    var host = Host.spawn(host_path, profile) catch return;
    var created = false;
    if (browsers_check.handshake(&host)) |_| {
        if (host.send(.{ .create_browser = .{ .browser = 1, .size = .{ .width = 64, .height = 64, .scale = 1 }, .hidden = false, .url = "about:blank" } })) |_| {
            const deadline = os.nowMs() + 120_000;
            while (!created and os.nowMs() < deadline) {
                const message = (host.next(1_000) catch |err| if (err == error.Timeout) continue else break) orelse break;
                if (message == .load_finished) created = true;
            }
        } else |_| {}
    } else |_| {}
    host.send(.shutdown) catch {};
    if (host.wait(15_000) == null) {
        _ = std.c.kill(host.pid, .KILL);
        _ = host.wait(15_000);
    }
    _ = std.c.close(host.commands);
    _ = std.c.close(host.events);
    std.debug.print("warm-up: host 첫 실행과 빈 페이지 {d} ms(판정 아님 — 불러옴 {})\n", .{ os.nowMs() - started, created });
}

/// 우클릭 메뉴 판정(W6c①) — 프로필은 `<뿌리>/k`.
fn contextMenuChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "contextmenu", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/k", .{profile_root}) catch return report(false, "contextmenu", "프로필 경로가 길다", .{});
    contextmenu_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "contextmenu", "{s}", .{@errorName(err)});
}

/// 끌어 놓기 판정(W6d①) — 프로필은 `<뿌리>/m`, 끌어 올 파일은 `<뿌리>/drag-files`.
fn dragChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "drag", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/m", .{profile_root}) catch return report(false, "drag", "프로필 경로가 길다", .{});
    drag_check.run(&reportText, host_path, profile, profile_root, server.port) catch |err| report(false, "drag", "{s}", .{@errorName(err)});
}

/// 새 탭 판정(W6e) — 프로필은 `<뿌리>/n`.
fn newTabChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "newtab", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/n", .{profile_root}) catch return report(false, "newtab", "프로필 경로가 길다", .{});
    newtab_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "newtab", "{s}", .{@errorName(err)});
}

/// 툴팁 판정(W6b) — 프로필은 `<뿌리>/j`.
fn tooltipChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "tooltip", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/j", .{profile_root}) catch return report(false, "tooltip", "프로필 경로가 길다", .{});
    tooltip_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "tooltip", "{s}", .{@errorName(err)});
}

/// 팝업 판정(W6a) — 프로필은 `<뿌리>/i`.
fn popupChecks(host_path: [:0]const u8, profile_root: []const u8) void {
    const server = http.Server.start() catch |err| return report(false, "popup", "HTTP 서버: {s}", .{@errorName(err)});
    var profile_buf: [1024]u8 = undefined;
    const profile = std.fmt.bufPrintZ(&profile_buf, "--profile-dir={s}/i", .{profile_root}) catch return report(false, "popup", "프로필 경로가 길다", .{});
    popup_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "popup", "{s}", .{@errorName(err)});
}

/// 입력 판정(W4). HTTP 서버는 판정마다 새로 연다(입력만 돌 때도 같은 페이지를 쓴다).
fn inputChecks(host_path: [:0]const u8, profile: [:0]const u8) void {
    const server = http.Server.start() catch |err| return report(false, "input", "HTTP 서버: {s}", .{@errorName(err)});
    input_check.run(&reportText, host_path, profile, server.port) catch |err| report(false, "input", "{s}", .{@errorName(err)});
}
