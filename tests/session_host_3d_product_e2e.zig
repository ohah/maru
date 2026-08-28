//! P5c3d current-product PTY E2E.
//!
//! This launches the built `maru __session-host`, a real host-owned PTY runtime, and independent
//! `openpty` CLI processes. The direct client is administrative only; all interactive assertions
//! cross the public product command and its raw-TTY/ANSI boundary.

const std = @import("std");
const session_host = @import("session_host");
const c = std.c;
const posix = std.posix;

extern "c" fn openpty(amaster: *c.fd_t, aslave: *c.fd_t, name: ?[*]u8, termp: ?*c.termios, winp: ?*const c.winsize) c_int;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn proc_listchildpids(ppid: c.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

const phase_ns: i128 = 15 * std.time.ns_per_s;
const sol_local: c_int = 0;
const local_peerpid: c_int = 0x002;
const darwin_tiocswinsz: c_int = @bitCast(@as(u32, 0x80087467));

test "p5c3d current product owns controller observer takeover detach and reattach over real PTY" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const product = try productExe(allocator);
    defer allocator.free(product);
    // P5d runs the same product oracle through a harness-owned OpenSSH wrapper. Keeping the
    // daemon executable separate prevents the SSH gate from replacing the host with a test double.
    const attach_product = if (c.getenv("MARU_SESSION_HOST_ATTACH_EXE")) |raw|
        try allocator.dupeZ(u8, std.mem.span(raw))
    else
        try allocator.dupeZ(u8, product);
    defer allocator.free(attach_product);
    // attach 를 제품 exe 로 직접 부르는 경우에만 로컬 termios 를 검증한다(SSH 래퍼면 원격이다).
    const verify_local_termios = std.mem.eql(u8, attach_product, product);

    var nonce: u64 = 0;
    c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    nonce = (nonce & (std.math.maxInt(u64) >> 1)) | 1;
    var xdg_buf: [256]u8 = undefined;
    const xdg = try std.fmt.bufPrintZ(&xdg_buf, "/tmp/maru-p5c3d-product-{x}", .{nonce});
    try mkdirExact(xdg);
    var xdg_exists = true;
    defer if (xdg_exists) removeTree(xdg);
    // base 를 **이 프로세스의 격리 root** 로 통일한다. registry(`{base}/session-host`)·socket(`{base}/sh`)·
    // 자식에게 넘기는 `MARU_SESSION_HOST_ROOT` 가 한 뿌리를 봐야 attach 가 성립한다 — 뿌리가 갈리면
    // 자식이 bind 한 socket 을 부모가 못 찾아 `P5C3D_READY` 마커 전에 죽는다.
    //
    // 예전에는 `{xdg}/maru` 를 썼는데, 그때는 socket 이 uid 로 고정이라 registry 만 옮겨지고 socket 은
    // 사용자의 공용 `/tmp/maru-<uid>/sh` 로 새어 나갔다. 아래 host_id 의 `0x5035633364707479`("P5c3dpty")
    // 가 실제로 사용자 registry 에서 발견된 가짜 항목의 정체다.
    var base_buf: [320]u8 = undefined;
    const base = try session_host.short_endpoint.currentUserRootPathIn(&base_buf);
    try session_host.short_endpoint.prepareCurrentUserNamespace();
    var session_buf: [384]u8 = undefined;
    const session_dir = try session_host.discovery.sessionHostDirPath(&session_buf, base);
    // 격리 root 는 **이 프로세스 공용**이라 앞선 테스트가 이미 만들어 뒀을 수 있다. 존재를 실패로 보지 않는다.
    if (c.mkdir(session_dir.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.MkdirFailed;

    const host_id: u128 = (@as(u128, nonce) << 64) | 0x5035633364707479;
    var socket_buf: [128]u8 = undefined;
    const socket_path = try session_host.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    _ = c.unlink(socket_path.ptr);
    const host_pid = try session_host.launcher.spawnSessionHostSupervisedForTest(
        allocator,
        product,
        session_dir,
        socket_path,
        host_id,
    );
    var host_reaped = false;
    defer if (!host_reaped) stopAndReap(host_pid);

    var admin = try connectExact(allocator, base, host_id);
    var admin_live = true;
    defer if (admin_live) admin.deinit();
    try std.testing.expectEqual(host_pid, try peerPid(admin.fd));
    var children_before: [64]c.pid_t = undefined;
    const children_before_len = listChildren(host_pid, &children_before);
    var input_probe_buf: [384]u8 = undefined;
    const input_probe = try std.fmt.bufPrintZ(&input_probe_buf, "{s}/input-probe", .{xdg});
    const spawn_params = try std.fmt.allocPrint(
        allocator,
        "{{\"argv\":[\"/bin/sh\",\"-c\",\"/bin/stty raw -echo -onlcr; printf 'P5C3D_READY 한글🙂'; exec /usr/bin/tee {s}\"],\"cols\":80,\"rows\":24}}",
        .{input_probe},
    );
    defer allocator.free(spawn_params);
    const spawn_response = try admin.call("runtime.spawn", spawn_params);
    defer allocator.free(spawn_response);
    const runtime_id = session_host.client.extractRuntimeId(spawn_response) orelse
        return error.RuntimeSpawnFailed;
    const runtime_pid = try waitForNewChild(
        host_pid,
        children_before[0..children_before_len],
    );
    var failure_stage: []const u8 = "runtime-ready";
    errdefer std.debug.print(
        "p5c3d product failure: stage={s} host_pid={d} runtime_pid={d} runtime_id={s}\n",
        .{ failure_stage, host_pid, runtime_pid, runtime_id },
    );

    // `runtime.spawn` admits the child before its first PTY burst is necessarily reduced into
    // TerminalCore. A read-only stream plus canonical `runtime.find` gives the fixture a product
    // readiness fence without taking controller authority or sleeping for scheduler luck.
    var readiness = try connectExact(allocator, base, host_id);
    defer readiness.deinit();
    const readiness_attach_params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"observer\"}}",
        .{runtime_id},
    );
    defer allocator.free(readiness_attach_params);
    const readiness_attach = try readiness.call("runtime.attach", readiness_attach_params);
    defer allocator.free(readiness_attach);
    const readiness_stream = session_host.client.extractU64Field(
        readiness_attach,
        "\"stream_id\":",
    ) orelse return error.ReadinessStreamMissing;
    const readiness_snapshot = try readiness.readSnapshot(readiness_stream);
    allocator.free(readiness_snapshot);
    try waitForStreamText(&readiness, readiness_stream, "50354333445f5245414459");
    var readiness_detach_buf: [64]u8 = undefined;
    const readiness_detach_params = try std.fmt.bufPrint(
        &readiness_detach_buf,
        "{{\"stream_id\":{d}}}",
        .{readiness_stream},
    );
    const readiness_detach = try readiness.call("runtime.detach", readiness_detach_params);
    allocator.free(readiness_detach);

    failure_stage = "controller";
    var controller = try PtyAttach.spawn(allocator, attach_product, base, &runtime_id, .controller);
    defer controller.deinit();
    errdefer std.debug.print(
        "p5c3d product controller failure: pid={d} status={any} output={any}\n",
        .{ controller.pid, controller.status, controller.bytes() },
    );
    try controller.waitFor("P5C3D_READY");
    try controller.write("P5C3D_INPUT\r");
    if (verify_local_termios) {
        // The direct child may leave the just-written byte readable on its local slave. OpenSSH
        // intentionally consumes it before forwarding, so P5d uses the stronger PTY-side exact
        // byte oracle below instead of requiring an implementation-specific intermediate state.
        var stdin_probe = [_]posix.pollfd{.{
            .fd = controller.slave,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = try posix.poll(&stdin_probe, 100);
        try std.testing.expect(stdin_probe[0].revents & posix.POLL.IN != 0);
    }
    try waitForFileBytesWhilePumping(input_probe, "P5C3D_INPUT\r", &controller);
    try controller.waitFor("P5C3D_INPUT");
    try controller.resize(100, 30);
    try waitForRuntimeSizeWhilePumping(
        allocator,
        &admin,
        &runtime_id,
        100,
        30,
        &controller,
    );
    try controller.detach();
    try std.testing.expectEqual(@as(c_int, 0), try controller.waitExit());
    try controller.expectRestoredAnsiAndTermios(verify_local_termios);
    try expectRuntimeAlive(host_pid, runtime_pid);

    failure_stage = "observer";
    var observer = try PtyAttach.spawn(allocator, attach_product, base, &runtime_id, .observer);
    defer observer.deinit();
    try observer.waitFor("P5C3D_INPUT");
    var sibling = try PtyAttach.spawn(allocator, attach_product, base, &runtime_id, .controller);
    defer sibling.deinit();
    try sibling.waitFor("P5C3D_INPUT");
    try sibling.write("P5C3D_SIBLING\r");
    try waitForFileBytesWhilePumping(input_probe, "P5C3D_SIBLING\r", &sibling);
    try sibling.waitFor("P5C3D_SIBLING");
    try observer.waitFor("P5C3D_SIBLING");
    const owned_size = try runtimeSize(allocator, &admin, &runtime_id);
    try observer.resize(120, 44);
    try observer.pumpFor(200 * std.time.ns_per_ms);
    try std.testing.expectEqual(owned_size, try runtimeSize(allocator, &admin, &runtime_id));
    try observer.write("OBSERVER_INJECTION\r");
    try sibling.pumpFor(200 * std.time.ns_per_ms);
    try std.testing.expect(std.mem.indexOf(u8, sibling.bytes(), "OBSERVER_INJECTION") == null);
    try observer.detach();
    try std.testing.expectEqual(@as(c_int, 0), try observer.waitExit());
    try observer.expectRestoredAnsiAndTermios(verify_local_termios);
    try sibling.detach();
    try std.testing.expectEqual(@as(c_int, 0), try sibling.waitExit());
    try sibling.expectRestoredAnsiAndTermios(verify_local_termios);

    failure_stage = "takeover";
    var old_controller = try PtyAttach.spawn(allocator, attach_product, base, &runtime_id, .controller);
    defer old_controller.deinit();
    try old_controller.waitFor("P5C3D_SIBLING");
    var takeover = try PtyAttach.spawn(allocator, attach_product, base, &runtime_id, .takeover);
    defer takeover.deinit();
    try takeover.waitFor("P5C3D_SIBLING");
    try std.testing.expectEqual(@as(c_int, 4), try old_controller.waitExit());
    try old_controller.expectRestoredAnsiAndTermios(verify_local_termios);
    try takeover.write("P5C3D_TAKEOVER\r");
    try takeover.waitFor("P5C3D_TAKEOVER");
    try takeover.detach();
    try std.testing.expectEqual(@as(c_int, 0), try takeover.waitExit());
    try takeover.expectRestoredAnsiAndTermios(verify_local_termios);

    failure_stage = "reattach";
    var reattach = try PtyAttach.spawn(allocator, attach_product, base, &runtime_id, .controller);
    defer reattach.deinit();
    try reattach.waitFor("P5C3D_TAKEOVER");
    try reattach.detach();
    try std.testing.expectEqual(@as(c_int, 0), try reattach.waitExit());
    try reattach.expectRestoredAnsiAndTermios(verify_local_termios);
    try expectRuntimeAlive(host_pid, runtime_pid);

    failure_stage = "cleanup";
    const terminate_params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\"}}",
        .{runtime_id},
    );
    defer allocator.free(terminate_params);
    const terminated = try admin.call("runtime.terminate", terminate_params);
    allocator.free(terminated);
    try waitForProcessGone(runtime_pid);
    admin.deinit();
    admin_live = false;
    stopAndReap(host_pid);
    host_reaped = true;
    removeTree(xdg);
    xdg_exists = false;
}

const AttachMode = enum { controller, observer, takeover };

test "p5c3d --stream 은 첫 화면 뒤 delta 를 계속 흘린다" {
    // **이 테스트가 없어서 두 결함이 함께 살아 있었다.**
    //   ① pump 를 안 세워 `transport` 가 null 이라 첫 호출이 `ConnectionClosed` → 그것을 정상
    //      종료로 접어 **첫 화면만 흘리고 즉시 끝났다**(실기에서 `exit=0`).
    //   ② 그것을 고친 뒤에도 `consumeCliOwnerProjection` 을 안 불러 이어받은 작업이 안 풀렸고,
    //      **apply 콜백이 한 번도 안 불렸다** — host 는 매초 delta 를 보내는데 화면이 멈춰 있었다.
    // 그래서 판정은 "바이트가 나온다" 가 아니라 **snapshot 뒤에 delta 가 이어지는가** 여야 한다.
    const allocator = std.testing.allocator;
    const product = try productExe(allocator);
    defer allocator.free(product);

    var nonce: u64 = 0;
    c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    nonce = (nonce & (std.math.maxInt(u64) >> 1)) | 1;
    var xdg_buf: [256]u8 = undefined;
    const xdg = try std.fmt.bufPrintZ(&xdg_buf, "/tmp/maru-p5c3d-stream-{x}", .{nonce});
    try mkdirExact(xdg);
    defer removeTree(xdg);
    // 위 테스트와 같은 이유로 base 를 **이 프로세스의 격리 root** 로 통일한다. 부모가 socket 을 여는
    // 뿌리와 자식에게 넘기는 `MARU_SESSION_HOST_ROOT` 가 갈리면 자식이 그 socket 을 찾지 못한다 —
    // 이 테스트에서는 delta 가 한 건도 오지 않아 `expected 1, found 0` 으로 떨어졌다.
    var base_buf: [288]u8 = undefined;
    const base = try session_host.short_endpoint.currentUserRootPathIn(&base_buf);
    try session_host.short_endpoint.prepareCurrentUserNamespace();
    var session_buf: [320]u8 = undefined;
    const session_dir = try session_host.discovery.sessionHostDirPath(&session_buf, base);
    // 격리 root 는 이 프로세스 공용이라 앞 테스트가 이미 만들어 뒀다. 존재를 실패로 보지 않는다.
    if (c.mkdir(session_dir.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.MkdirFailed;

    const host_id: u128 = (@as(u128, nonce) << 64) | 0x50356333647374726d;
    var socket_buf: [128]u8 = undefined;
    const socket_path = try session_host.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    _ = c.unlink(socket_path.ptr);
    const host_pid = try session_host.launcher.spawnSessionHostSupervisedForTest(
        allocator,
        product,
        session_dir,
        socket_path,
        host_id,
    );
    defer stopAndReap(host_pid);

    var admin = try connectExact(allocator, base, host_id);
    defer admin.deinit();

    // **화면이 계속 바뀌는 runtime.** 정적인 화면이면 delta 가 안 와서 이 테스트가 아무것도 못 잰다.
    const spawn_response = try admin.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/sh\",\"-c\",\"i=0; while :; do printf 'tick %s\\n' $i; i=$((i+1)); sleep 1; done\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(spawn_response);
    const runtime_id = session_host.client.extractRuntimeId(spawn_response) orelse
        return error.RuntimeSpawnFailed;
    var runtime_text: [33]u8 = undefined;
    const runtime_z = try std.fmt.bufPrintZ(&runtime_text, "{s}", .{&runtime_id});

    // `--stream` 은 pty 가 필요 없다 — **파이프로 돌리는 것이 이 모드의 목적이다**(§8).
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    const read_fd = try moveAboveStdio(pipe_fds[0]);
    const write_fd = try moveAboveStdio(pipe_fds[1]);

    var root_env: [320]u8 = undefined;
    const root_arg = try std.fmt.bufPrintZ(&root_env, "MARU_SESSION_HOST_ROOT={s}", .{base});
    const child = c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = c.dup2(write_fd, 1);
        _ = c.close(read_fd);
        _ = c.close(write_fd);
        const argv = [_:null]?[*:0]const u8{ "env", root_arg.ptr, product.ptr, "attach", "--stream", runtime_z.ptr };
        _ = c.execve("/usr/bin/env", &argv, @ptrCast(c.environ));
        c._exit(127);
    }
    _ = c.close(write_fd);
    defer {
        _ = c.kill(child, c.SIG.TERM);
        var status: c_int = 0;
        _ = c.waitpid(child, &status, 0);
        _ = c.close(read_fd);
    }

    // 프레임을 모은다. delta 는 원격이 1초마다 한 줄을 내므로 넉넉히 기다린다.
    var buf: [256 * 1024]u8 = undefined;
    var len: usize = 0;
    var snapshots: usize = 0;
    var deltas: usize = 0;
    var waited_ms: usize = 0;
    while (waited_ms < 15_000 and deltas < 2) : (waited_ms += 100) {
        var fds = [_]posix.pollfd{.{ .fd = read_fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, 100) catch break;
        if (ready > 0 and fds[0].revents & posix.POLL.IN != 0) {
            const n = c.read(read_fd, buf[len..].ptr, buf.len - len);
            if (n <= 0) break;
            len += @intCast(n);
        }
        // 모인 만큼 프레임 경계를 다시 센다(부분 프레임은 다음 회차에 이어 읽는다).
        snapshots = 0;
        deltas = 0;
        var off: usize = 0;
        while (off + stream_header_bytes <= len) {
            if (!std.mem.eql(u8, buf[off..][0..4], "MRSS")) return error.StreamFramingBroken;
            const payload_len = std.mem.readInt(u32, buf[off + 8 ..][0..4], .little);
            if (off + stream_header_bytes + payload_len > len) break; // 아직 덜 왔다
            switch (buf[off + 4]) {
                0 => snapshots += 1,
                1 => deltas += 1,
                else => return error.StreamFramingBroken,
            }
            off += stream_header_bytes + payload_len;
        }
    }

    // 첫 화면은 정확히 하나다 — 그 뒤는 이어받기(delta)여야 한다.
    try std.testing.expectEqual(@as(usize, 1), snapshots);
    // **여기가 회귀의 핵심이다.** 예전 구현은 여기서 0 이었다.
    try std.testing.expect(deltas >= 2);
    // 그리고 프로세스는 **아직 살아 있어야** 한다 — 즉시 종료가 첫 번째 결함이었다.
    try std.testing.expectEqual(@as(c.pid_t, 0), c.waitpid(child, null, 1));
}

/// `--stream` stdout 프레이밍 헤더 크기(§8). 소비자가 세는 자리라 여기서도 같은 값을 쓴다.
const stream_header_bytes: usize = 12;

/// 제품 exe 경로. **이 env 를 읽는 자리는 하나여야 한다** — 경계 게이트가 "제품 프로세스
/// 호출자 하나" 로 그것을 고정한다(`tests/session_host_3d_boundary.zig`). 없으면 이 스위트는
/// 제품 없이 돌 수 없으므로 건너뛴다.
fn productExe(allocator: std.mem.Allocator) ![:0]u8 {
    const raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    return allocator.dupeZ(u8, std.mem.span(raw));
}

const PtyAttach = struct {
    allocator: std.mem.Allocator,
    master: c.fd_t,
    slave: c.fd_t,
    pid: c.pid_t,
    before: c.termios,
    output: []u8,
    used: usize = 0,
    status: ?c_int = null,

    fn spawn(
        allocator: std.mem.Allocator,
        product: [:0]const u8,
        session_host_root: [:0]const u8,
        runtime_id: *const [32]u8,
        mode: AttachMode,
    ) !PtyAttach {
        var master: c.fd_t = -1;
        var slave: c.fd_t = -1;
        if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
        errdefer _ = c.close(master);
        errdefer _ = c.close(slave);
        master = try moveAboveStdio(master);
        slave = try moveAboveStdio(slave);
        var window = posix.winsize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        if (c.ioctl(slave, darwin_tiocswinsz, &window) != 0) return error.WindowSizeFailed;
        var before: c.termios = undefined;
        if (c.tcgetattr(slave, &before) != 0) return error.TermiosFailed;
        const output = try allocator.alloc(u8, 512 * 1024);
        errdefer allocator.free(output);
        var env_buf: [320]u8 = undefined;
        const env_arg = try std.fmt.bufPrintZ(&env_buf, "MARU_SESSION_HOST_ROOT={s}", .{session_host_root});
        var runtime_buf: [33]u8 = undefined;
        const runtime_z = try std.fmt.bufPrintZ(&runtime_buf, "{s}", .{runtime_id});
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);
            _ = c.close(master);
            _ = c.close(slave);
            const controller = [_:null]?[*:0]const u8{ "env", env_arg.ptr, product.ptr, "attach", runtime_z.ptr };
            const observer = [_:null]?[*:0]const u8{ "env", env_arg.ptr, product.ptr, "attach", "--read-only", runtime_z.ptr };
            const takeover = [_:null]?[*:0]const u8{ "env", env_arg.ptr, product.ptr, "attach", "--take-over", runtime_z.ptr };
            const argv = switch (mode) {
                .controller => &controller,
                .observer => &observer,
                .takeover => &takeover,
            };
            _ = c.execve("/usr/bin/env", argv, @ptrCast(c.environ));
            c._exit(127);
        }
        return .{
            .allocator = allocator,
            .master = master,
            .slave = slave,
            .pid = pid,
            .before = before,
            .output = output,
        };
    }

    fn deinit(self: *PtyAttach) void {
        if (self.status == null) {
            _ = c.kill(self.pid, c.SIG.KILL);
            _ = self.waitExit() catch {};
        }
        _ = c.close(self.master);
        _ = c.close(self.slave);
        self.allocator.free(self.output);
        self.* = undefined;
    }

    fn bytes(self: *const PtyAttach) []const u8 {
        return self.output[0..self.used];
    }

    fn readReady(self: *PtyAttach, timeout_ms: c_int) !bool {
        var fds = [_]posix.pollfd{.{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&fds, timeout_ms) catch return error.PollFailed;
        // A PTY may report POLLHUP together with unread final stderr after the child exits.
        // Attempt the read in either case so failure diagnostics are not discarded at teardown.
        if (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0) return false;
        if (self.used == self.output.len) return error.OutputOverflow;
        const count = c.read(self.master, self.output[self.used..].ptr, self.output.len - self.used);
        if (count > 0) {
            self.used += @intCast(count);
            return true;
        }
        if (count < 0 and posix.errno(count) == .INTR) return false;
        return false;
    }

    fn waitFor(self: *PtyAttach, needle: []const u8) !void {
        const started = monotonicNow();
        while (monotonicNow() - started < phase_ns) {
            if (containsVisibleText(self.bytes(), needle)) return;
            _ = try self.readReady(20);
            if (try self.tryWait()) |status| {
                std.debug.print(
                    "p5c3d attachment exited before marker: pid={d} status={d} marker={s} output={any}\n",
                    .{ self.pid, status, needle, self.bytes() },
                );
                return error.ChildExitedEarly;
            }
        }
        return error.MarkerTimeout;
    }

    fn pumpFor(self: *PtyAttach, duration_ns: i128) !void {
        const started = monotonicNow();
        while (monotonicNow() - started < duration_ns) {
            _ = try self.readReady(10);
            if (try self.tryWait()) |_| return;
        }
    }

    fn write(self: *PtyAttach, value: []const u8) !void {
        try writeAll(self.master, value);
    }

    fn resize(self: *PtyAttach, cols: u16, rows: u16) !void {
        var window = posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (c.ioctl(self.slave, darwin_tiocswinsz, &window) != 0)
            return error.WindowSizeFailed;
        if (c.kill(self.pid, c.SIG.WINCH) != 0) return error.SignalFailed;
    }

    fn detach(self: *PtyAttach) !void {
        try self.write(&.{ 0x1c, 'd' });
    }

    fn tryWait(self: *PtyAttach) !?c_int {
        if (self.status) |status| return status;
        var status: c_int = 0;
        const waited = c.waitpid(self.pid, &status, c.W.NOHANG);
        if (waited == 0) return null;
        if (waited < 0) {
            if (posix.errno(waited) == .INTR) return null;
            return error.WaitFailed;
        }
        self.status = status;
        return status;
    }

    fn waitExit(self: *PtyAttach) !c_int {
        const started = monotonicNow();
        while (monotonicNow() - started < phase_ns) {
            _ = try self.readReady(20);
            if (try self.tryWait()) |status| {
                while (try self.readReady(0)) {}
                const unsigned: u32 = @bitCast(status);
                return if (c.W.IFEXITED(unsigned))
                    @intCast(c.W.EXITSTATUS(unsigned))
                else
                    -1;
            }
        }
        return error.ChildExitTimeout;
    }

    fn expectRestoredAnsiAndTermios(self: *PtyAttach, verify_local_termios: bool) !void {
        var after: c.termios = undefined;
        if (c.tcgetattr(self.slave, &after) != 0) return error.TermiosFailed;
        // Direct `maru attach` owns this PTY and must restore every byte. P5d inserts the system
        // OpenSSH client, which owns and may normalize its local PTY flags; Maru still has to emit
        // its exact leave sequence and restore the remote PTY before SSH exits.
        if (verify_local_termios) {
            try std.testing.expectEqualSlices(
                u8,
                std.mem.asBytes(&self.before),
                std.mem.asBytes(&after),
            );
        }
        try expectAnsiOracle(self.bytes());
    }
};

fn containsVisibleText(bytes: []const u8, needle: []const u8) bool {
    // Product repaint positions and styles individual cells, so a visible word
    // is not necessarily contiguous on the wire. Decode the CSI envelope into
    // a plain printable stream instead of weakening the oracle to raw bytes.
    var plain: [512 * 1024]u8 = undefined;
    var used: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != 0x1b) {
            if (bytes[index] >= 0x20 and bytes[index] != 0x7f) {
                plain[used] = bytes[index];
                used += 1;
            }
            index += 1;
            continue;
        }
        index += 1;
        if (index == bytes.len) break;
        if (bytes[index] != '[') {
            index += 1;
            continue;
        }
        index += 1;
        while (index < bytes.len and
            !(bytes[index] >= 0x40 and bytes[index] <= 0x7e)) : (index += 1)
        {}
        if (index < bytes.len) index += 1;
    }
    return std.mem.indexOf(u8, plain[0..used], needle) != null;
}

fn expectAnsiOracle(bytes: []const u8) !void {
    const enter = "\x1b[?1049h\x1b[?25l";
    const leave = "\x1b[0m\x1b[?25h\x1b[?1049l";
    try std.testing.expect(std.mem.startsWith(u8, bytes, enter));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\x1b[?1049l"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, leave) != null);
    var alternate = false;
    var cursor_visible = true;
    var style_reset = false;
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] != 0x1b) {
            index += 1;
            continue;
        }
        if (index + 1 >= bytes.len or bytes[index + 1] != '[')
            return error.UnexpectedAnsiEscape;
        const start = index + 2;
        index = start;
        while (index < bytes.len and
            !(bytes[index] >= 0x40 and bytes[index] <= 0x7e)) : (index += 1)
        {}
        if (index == bytes.len) return error.TruncatedAnsiEscape;
        const sequence = bytes[start .. index + 1];
        if (std.mem.eql(u8, sequence, "?1049h")) alternate = true;
        if (std.mem.eql(u8, sequence, "?1049l")) alternate = false;
        if (std.mem.eql(u8, sequence, "?25h")) cursor_visible = true;
        if (std.mem.eql(u8, sequence, "?25l")) cursor_visible = false;
        if (std.mem.eql(u8, sequence, "0m")) style_reset = true;
        index += 1;
    }
    try std.testing.expect(!alternate);
    try std.testing.expect(cursor_visible);
    try std.testing.expect(style_reset);
}

const RuntimeSize = struct { cols: u64, rows: u64 };

fn runtimeSize(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    runtime_id: *const [32]u8,
) !RuntimeSize {
    const params = try std.fmt.allocPrint(allocator, "{{\"runtime_id\":\"{s}\"}}", .{runtime_id});
    defer allocator.free(params);
    const response = try client.call("runtime.get", params);
    defer allocator.free(response);
    return .{
        .cols = session_host.client.extractU64Field(response, "\"cols\":") orelse return error.RuntimeSizeMissing,
        .rows = session_host.client.extractU64Field(response, "\"rows\":") orelse return error.RuntimeSizeMissing,
    };
}

fn waitForRuntimeSize(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    runtime_id: *const [32]u8,
    cols: u64,
    rows: u64,
) !void {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        const size = try runtimeSize(allocator, client, runtime_id);
        if (size.cols == cols and size.rows == rows) return;
        _ = usleep(10_000);
    }
    return error.ResizeTimeout;
}

fn waitForStreamText(
    client: *session_host.client.Client,
    stream_id: u64,
    query_hex: []const u8,
) !void {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        var params_buf: [160]u8 = undefined;
        const params = try std.fmt.bufPrint(
            &params_buf,
            "{{\"stream_id\":{d},\"q\":\"{s}\",\"scroll\":false}}",
            .{ stream_id, query_hex },
        );
        const response = try client.call("runtime.find", params);
        const count = session_host.client.extractU64Field(response, "\"count\":") orelse 0;
        client.allocator.free(response);
        if (count > 0) return;
        _ = usleep(10_000);
    }
    return error.RuntimeReadyTimeout;
}

fn waitForRuntimeSizeWhilePumping(
    allocator: std.mem.Allocator,
    client: *session_host.client.Client,
    runtime_id: *const [32]u8,
    cols: u64,
    rows: u64,
    attach: *PtyAttach,
) !void {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        _ = try attach.readReady(10);
        if (try attach.tryWait()) |_| return error.ChildExitedEarly;
        const size = try runtimeSize(allocator, client, runtime_id);
        if (size.cols == cols and size.rows == rows) return;
    }
    return error.ResizeTimeout;
}

fn connectExact(allocator: std.mem.Allocator, base: []const u8, host_id: u128) !session_host.client.Client {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        switch (session_host.host_connect.connectExistingHost(allocator, base, host_id)) {
            .connected => |client| return client,
            .failed => {
                _ = usleep(10_000);
                continue;
            },
        }
    }
    return error.HostConnectTimeout;
}

fn peerPid(fd: c.fd_t) !c.pid_t {
    var pid: c.pid_t = 0;
    var len: c.socklen_t = @sizeOf(c.pid_t);
    if (c.getsockopt(fd, sol_local, local_peerpid, &pid, &len) != 0 or
        len != @sizeOf(c.pid_t) or pid <= 0)
        return error.PeerPidUnavailable;
    return pid;
}

fn listChildren(parent: c.pid_t, buffer: *[64]c.pid_t) usize {
    @memset(buffer, 0);
    // libproc returns a PID count here, not the number of bytes written. Dividing
    // it by sizeof(pid_t) makes the common one-child host look childless and
    // turns a healthy runtime into a misleading discovery timeout.
    const count = proc_listchildpids(parent, buffer, @intCast(@sizeOf(@TypeOf(buffer.*))));
    if (count <= 0) return 0;
    return @min(buffer.len, @as(usize, @intCast(count)));
}

fn waitForNewChild(parent: c.pid_t, before: []const c.pid_t) !c.pid_t {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        var current: [64]c.pid_t = undefined;
        const count = listChildren(parent, &current);
        for (current[0..count]) |pid|
            if (pid > 0 and std.mem.indexOfScalar(c.pid_t, before, pid) == null)
                return pid;
        _ = usleep(10_000);
    }
    return error.RuntimePidUnavailable;
}

fn expectRuntimeAlive(host_pid: c.pid_t, runtime_pid: c.pid_t) !void {
    const probe_signal: c.SIG = @enumFromInt(0);
    if (c.kill(host_pid, probe_signal) != 0 or c.kill(runtime_pid, probe_signal) != 0)
        return error.ProcessNotAlive;
    var children: [64]c.pid_t = undefined;
    const count = listChildren(host_pid, &children);
    if (std.mem.indexOfScalar(c.pid_t, children[0..count], runtime_pid) == null)
        return error.RuntimeParentChanged;
}

fn waitForProcessGone(pid: c.pid_t) !void {
    const probe_signal: c.SIG = @enumFromInt(0);
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        const rc = c.kill(pid, probe_signal);
        if (rc != 0 and posix.errno(rc) == .SRCH) return;
        _ = usleep(10_000);
    }
    return error.ProcessExitTimeout;
}

fn waitForFileBytes(path: [:0]const u8, expected: []const u8) !void {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
        if (fd >= 0) {
            defer _ = c.close(fd);
            var bytes: [128]u8 = undefined;
            const count = c.read(fd, &bytes, bytes.len);
            if (count >= 0 and std.mem.indexOf(u8, bytes[0..@intCast(count)], expected) != null)
                return;
        }
        _ = usleep(10_000);
    }
    return error.PtyInputOracleTimeout;
}

fn waitForFileBytesWhilePumping(
    path: [:0]const u8,
    expected: []const u8,
    attachment: *PtyAttach,
) !void {
    const started = monotonicNow();
    while (monotonicNow() - started < phase_ns) {
        const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
        if (fd >= 0) {
            defer _ = c.close(fd);
            var bytes: [128]u8 = undefined;
            const count = c.read(fd, &bytes, bytes.len);
            if (count >= 0 and std.mem.indexOf(u8, bytes[0..@intCast(count)], expected) != null)
                return;
        }
        // The CLI owns a bounded stdout repaint queue. Keep consuming the real TTY while waiting
        // on the child-side oracle so the test itself cannot manufacture output backpressure that
        // starves the lower-priority stdin turn.
        _ = try attachment.readReady(10);
        if (try attachment.tryWait()) |status| {
            while (try attachment.readReady(0)) {}
            std.debug.print(
                "p5c3d attachment exited before PTY input oracle: pid={d} status={d} expected={s} output={any}\n",
                .{ attachment.pid, status, expected, attachment.bytes() },
            );
            return error.ChildExitedEarly;
        }
    }
    return error.PtyInputOracleTimeout;
}

fn stopAndReap(pid: c.pid_t) void {
    _ = c.kill(pid, c.SIG.TERM);
    var status: c_int = 0;
    for (0..200) |_| {
        const waited = c.waitpid(pid, &status, c.W.NOHANG);
        if (waited == pid or (waited < 0 and posix.errno(waited) == .CHILD)) return;
        _ = usleep(10_000);
    }
    _ = c.kill(pid, c.SIG.KILL);
    while (true) {
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid or (waited < 0 and posix.errno(waited) == .CHILD)) return;
        if (waited < 0 and posix.errno(waited) != .INTR) return;
    }
}

fn moveAboveStdio(fd: c.fd_t) !c.fd_t {
    if (fd > 2) {
        const flags = c.fcntl(fd, c.F.GETFD);
        if (flags < 0 or c.fcntl(fd, c.F.SETFD, flags | c.FD_CLOEXEC) < 0)
            return error.FdFlagFailed;
        return fd;
    }
    const moved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (moved < 0) return error.FdMoveFailed;
    _ = c.close(fd);
    return moved;
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count < 0 and posix.errno(count) == .INTR) continue;
        return error.WriteFailed;
    }
}

fn monotonicNow() i128 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}

fn mkdirExact(path: [:0]const u8) !void {
    if (c.mkdir(path.ptr, 0o700) != 0) return error.MkdirFailed;
}

fn removeTree(path: [:0]const u8) void {
    var tmp = std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{}) catch return;
    defer tmp.close(std.testing.io);
    const leaf = std.fs.path.basename(path);
    tmp.deleteTree(std.testing.io, leaf) catch {};
}
