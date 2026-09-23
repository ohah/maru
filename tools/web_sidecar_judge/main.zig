//! 웹 OSR sidecar W1b 판정자 — `maru-web-judge <설치 디렉터리> <프로필 뿌리>`.
//!
//! 실제 `maru-web-host` 를 maru 처럼 띄워 docs/plans/web-osr-backend.md 「W1b」 완료 판정을 잰다:
//!   handshake        hello → 같은 instance·nonce 의 hello_ack
//!   helper-sandbox   host 의 자식이 모두 `maru-web-helper` 이고 `sandbox_check` 1(host 자신은 샌드박스 밖)
//!   browser-refused  W1c 전의 create_browser 에 browser_create_failed 로 답한다
//!   shutdown-clean   shutdown → 알림이 끝까지 frame 으로만 풀리고(stdout 오염 없음) exit 0, helper 도 사라진다
//!   parent-death     maru 역할 프로세스를 SIGKILL 하면 host 와 helper 가 모두 사라진다(고아 Chromium 없음)
//! 하나라도 틀리면 exit 1.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;

const helper_wait_ms = 20_000;
const exit_wait_ms = 20_000;
/// 알림 하나를 기다리는 상한 — 초기화 직후의 답도 이 안에 온다.
const reply_wait_ms = 15_000;

var failures: u32 = 0;

fn report(ok: bool, name: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!ok) failures += 1;
    std.debug.print("{s} {s}: " ++ fmt ++ "\n", .{ if (ok) "PASS" else "FAIL", name } ++ args);
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len != 3) {
        std.debug.print("사용: maru-web-judge <설치 디렉터리> <프로필 뿌리>\n", .{});
        return 2;
    }
    const install_dir = std.mem.span(argv[1]);
    const profile_root = std.mem.span(argv[2]);

    var host_path_buf: [1024]u8 = undefined;
    const host_path = std.fmt.bufPrintZ(&host_path_buf, "{s}/maru-web-host", .{install_dir}) catch return 2;
    var profile_a_buf: [1024]u8 = undefined;
    const profile_a = std.fmt.bufPrintZ(&profile_a_buf, "--profile-dir={s}/a", .{profile_root}) catch return 2;
    var profile_b_buf: [1024]u8 = undefined;
    const profile_b = std.fmt.bufPrintZ(&profile_b_buf, "--profile-dir={s}/b", .{profile_root}) catch return 2;

    sessionChecks(host_path, profile_a) catch |err| report(false, "session", "{s}", .{@errorName(err)});
    parentDeath(host_path, profile_b) catch |err| report(false, "parent-death", "{s}", .{@errorName(err)});

    std.debug.print("{s}: 틀림 {d} 건\n", .{ if (failures == 0) "통과" else "실패", failures });
    return if (failures == 0) 0 else 1;
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
    const state = settleSandboxed(host.pid, &kids_buf);
    const host_outside = os.sandbox_check(host.pid, null, 0) == 0;
    report(state.all() and host_outside, "helper-sandbox", "helper {d} 개 · 샌드박스 {d} · 이름 일치 {d} · host 샌드박스 밖 {}", .{ state.total, state.sandboxed, state.named, host_outside });

    try host.send(.{ .create_browser = .{ .browser = 41, .size = .{ .width = 400, .height = 300, .scale = 2 }, .hidden = false, .url = "about:blank" } });
    const refused = (try host.next(reply_wait_ms)) orelse return error.ClosedBeforeRefusal;
    report(refused == .failure and refused.failure.browser == 41 and refused.failure.code == .browser_create_failed, "browser-refused", "{s}", .{@tagName(refused)});

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
        const pid_bytes = std.mem.asBytes(&host.pid);
        _ = std.c.write(report_pipe[1], pid_bytes.ptr, pid_bytes.len);
        while (true) os.sleepMs(1000);
    }
    _ = std.c.close(report_pipe[1]);
    var host_pid: c_int = 0;
    if (std.c.read(report_pipe[0], std.mem.asBytes(&host_pid).ptr, @sizeOf(c_int)) != @sizeOf(c_int)) return error.NoHostPid;

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

const SandboxState = struct {
    total: usize,
    sandboxed: usize,
    named: usize,

    fn all(self: SandboxState) bool {
        return self.total >= 2 and self.sandboxed == self.total and self.named == self.total;
    }
};

/// 막 fork 된 자식은 아직 exec 전이라 경로가 host 이고, helper 는 `cef_sandbox_initialize` 에 닿기 전 잠깐 샌드박스
/// 밖이다(실측 — 1 초 시점에는 GPU·네트워크·저장소 셋 다 샌드박스 안). 그래서 제한 시간 안에 **모두** 샌드박스 안
/// helper 가 되는지 본다. 끝내 안 되면 마지막 관찰을 돌려줘 실패로 판정된다.
fn settleSandboxed(host_pid: c_int, buf: []c_int) SandboxState {
    var path_buf: [4096]u8 = undefined;
    var state: SandboxState = .{ .total = 0, .sandboxed = 0, .named = 0 };
    var waited: u32 = 0;
    while (waited <= helper_wait_ms) : (waited += 200) {
        const kids = os.children(host_pid, buf);
        state = .{ .total = kids.len, .sandboxed = 0, .named = 0 };
        for (kids) |pid| {
            if (os.sandbox_check(pid, null, 0) == 1) state.sandboxed += 1;
            if (std.mem.endsWith(u8, os.executablePath(pid, &path_buf), "/maru-web-helper")) state.named += 1;
        }
        if (state.all()) return state;
        os.sleepMs(200);
    }
    return state;
}

fn allGone(pids: []const c_int, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (waited <= timeout_ms) : (waited += 100) {
        var any = false;
        for (pids) |pid| {
            if (os.alive(pid)) any = true;
        }
        if (!any) return true;
        os.sleepMs(100);
    }
    return false;
}
