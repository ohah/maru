//! P5c3d same-major compatibility product E2E.
//!
//! The old host is a separately built process whose source imports no current Maru module. This
//! driver owns only fixture setup, a real current `maru` subprocess, an `openpty` controller, and
//! bounded cleanup. Every wait has a five-second monotonic deadline.

const std = @import("std");
const session_host = @import("session_host");
const provenance = @import("fixtures/session_host_pre_p5b3_v2_provenance.zig");
const c = std.c;
const posix = std.posix;

extern "c" fn openpty(amaster: *c.fd_t, aslave: *c.fd_t, name: ?[*]u8, termp: ?*c.termios, winp: ?*const c.winsize) c_int;
extern "c" fn usleep(usec: c_uint) c_int;

const deadline_ns: i128 = 5 * std.time.ns_per_s;
const process_deadline_ns: i128 = 30 * std.time.ns_per_s;
const darwin_tiocswinsz: c_int = @bitCast(@as(u32, 0x80087467));

test "p5c3d frozen same-major host permits observer detach and rejects takeover before wire mutation" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const product_raw = c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse return error.SkipZigTest;
    const fixture_raw = c.getenv("MARU_SESSION_HOST_PRE_P5B3_EXE") orelse return error.SkipZigTest;
    const product = std.mem.span(product_raw);
    const fixture = std.mem.span(fixture_raw);
    const allocator = std.testing.allocator;
    try verifyFrozenSource(allocator);

    var nonce: u64 = 0;
    c.arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    nonce = (nonce & (std.math.maxInt(u64) >> 1)) | 1;
    var xdg_buf: [256]u8 = undefined;
    const xdg = try std.fmt.bufPrintZ(&xdg_buf, "/tmp/maru-p5c3d-{x}", .{nonce});
    try mkdirExact(xdg);
    defer _ = c.rmdir(xdg.ptr);
    // base 를 **이 프로세스의 격리 root** 로 통일한다. registry(`{base}/session-host`)·socket(`{base}/sh`)·
    // 자식에게 넘기는 `MARU_SESSION_HOST_ROOT` 가 한 뿌리를 봐야 attach 가 성립한다.
    //
    // 예전에는 `{xdg}/maru` 를 썼다. 그때는 socket 이 uid 로 고정이라 registry 만 옮겨져도 부모가 만든
    // socket 과 자식이 찾는 socket 이 우연히 같은 `/tmp/maru-<uid>/sh` 에서 만났다. override 가 socket 까지
    // 옮기게 된 지금은 그 우연이 사라져, 부모는 격리 root 에 bind 하고 자식은 `{xdg}/maru/sh` 를 뒤지다
    // observer 가 exit 4 로 죽는다. `{xdg}` 는 snapshot·report 자리로만 남는다.
    var base_buf: [320]u8 = undefined;
    const base = try session_host.short_endpoint.currentUserRootPathIn(&base_buf);
    try session_host.short_endpoint.prepareCurrentUserNamespace();
    var session_buf: [512]u8 = undefined;
    const session_dir = try session_host.discovery.sessionHostDirPath(&session_buf, base);
    // 격리 root 는 **이 프로세스 공용**이라 앞선 테스트가 이미 만들어 뒀을 수 있다. 존재를 실패로 보지 않는다.
    if (c.mkdir(session_dir.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.MkdirFailed;

    const host_id: u128 = (@as(u128, nonce) << 64) | 0x503562337632;
    const runtime_id: u128 = (@as(u128, nonce) << 64) | 0x72756e74696d65;
    var host_text_buf: [33]u8 = undefined;
    const host_text = try std.fmt.bufPrintZ(&host_text_buf, "{x:0>32}", .{host_id});
    var runtime_text_buf: [33]u8 = undefined;
    const runtime_text = try std.fmt.bufPrintZ(&runtime_text_buf, "{x:0>32}", .{runtime_id});
    var socket_buf: [128]u8 = undefined;
    const socket_path = try session_host.short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    defer _ = c.unlink(socket_path.ptr);
    try session_host.host_manifest.prepareHostDirectory(session_dir, host_id);
    var owner_buf: [832]u8 = undefined;
    const owner_path = try session_host.host_manifest.ownerLockPathIn(&owner_buf, session_dir, host_id);
    defer _ = c.unlink(owner_path.ptr);
    var snapshot_buf: [384]u8 = undefined;
    const snapshot_path = try std.fmt.bufPrintZ(&snapshot_buf, "{s}/snapshot.bin", .{xdg});
    defer _ = c.unlink(snapshot_path.ptr);
    var report_buf: [384]u8 = undefined;
    const report_path = try std.fmt.bufPrintZ(&report_buf, "{s}/report.txt", .{xdg});
    defer _ = c.unlink(report_path.ptr);
    try writeSnapshot(allocator, snapshot_path);

    const fixture_z = try allocator.dupeZ(u8, fixture);
    defer allocator.free(fixture_z);
    const build_id = try session_host.host_manifest.buildIdForExecutable(allocator, fixture_z);
    defer allocator.free(build_id);
    const build_id_z = try allocator.dupeZ(u8, build_id);
    defer allocator.free(build_id_z);
    const fixture_pid = try spawnFixture(fixture, socket_path, host_text, runtime_text, snapshot_path, report_path, owner_path, build_id_z);
    defer killAndReap(fixture_pid);
    try waitForText(report_path, "ready\n");
    var publication = try session_host.host_manifest.publish(allocator, session_dir, .{
        .host_id = host_id,
        .build_id = build_id,
        .protocol_major = 2,
        .screen_codec_version = 2,
        .upgrade_epoch = 0,
        .lifecycle = .ready,
        .endpoint = socket_path,
    });
    defer publication.deinit();

    // A pre-transfer GUI remains the controller throughout the current CLI takeover attempt.
    var legacy = session_host.client.Client.connect(allocator, socket_path, .gui) catch |err| {
        const diagnostic = readFile(allocator, report_path, 64 * 1024) catch &.{};
        defer if (diagnostic.len > 0) allocator.free(diagnostic);
        std.debug.print("p5c3d fixture connect failed: {s}; report={s}\n", .{ @errorName(err), diagnostic });
        return err;
    };
    defer legacy.deinit();
    const attach_params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\"}}",
        .{runtime_text},
    );
    defer allocator.free(attach_params);
    const attached = try legacy.call("runtime.attach", attach_params);
    defer allocator.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "\"input\":true") != null);
    const legacy_snapshot = try legacy.readSnapshot(1);
    defer allocator.free(legacy_snapshot);
    try legacy.sendInput(1, "before");

    var discovered = session_host.recovery_discovery.discover(allocator, session_dir);
    defer discovered.deinit(allocator);
    switch (discovered) {
        .unavailable => |reason| {
            std.debug.print("p5c3d discovery unavailable: {s}\n", .{@tagName(reason)});
            return error.ProductDiscoveryFailed;
        },
        .complete => |entries| {
            if (entries.len != 1) {
                std.debug.print("p5c3d discovery entries={d}\n", .{entries.len});
                return error.ProductDiscoveryFailed;
            }
            switch (entries[0]) {
                .candidate => |candidate| {
                    var direct = session_host.host_connect.connectDiscoveredHostProfile(
                        allocator,
                        base,
                        candidate.manifest.descriptor(),
                        .cli_probe,
                    );
                    switch (direct) {
                        .connected => |*client| client.deinit(),
                        .failed => |reason| {
                            const diagnostic = try readFile(allocator, report_path, 64 * 1024);
                            defer allocator.free(diagnostic);
                            std.debug.print("p5c3d direct connect failed: {s}; report={s}\n", .{ @tagName(reason), diagnostic });
                            return error.ProductConnectFailed;
                        },
                    }
                },
                .unavailable => |entry| {
                    std.debug.print("p5c3d discovery entry unavailable: {s}\n", .{@tagName(entry.reason)});
                    return error.ProductDiscoveryFailed;
                },
            }
        },
    }

    const resolve_phase = try session_host.attach_phase_deadline.PhaseDeadline.start(
        std.testing.io,
        .resolve,
    );
    var resolved = switch (session_host.attach_product_resolver.resolveProduct(
        allocator,
        base,
        runtime_id,
        resolve_phase,
    )) {
        .selected => |value| value,
        .failed => |code| {
            const diagnostic = try readFile(allocator, report_path, 64 * 1024);
            defer allocator.free(diagnostic);
            std.debug.print("p5c3d direct resolver failed: {s}; report={s}\n", .{ @tagName(code), diagnostic });
            return error.ProductResolverFailed;
        },
    };
    resolved.deinit();

    const observer = runProductAttach(product, base, runtime_text, .observer) catch |err| {
        const diagnostic = try readFile(allocator, report_path, 64 * 1024);
        defer allocator.free(diagnostic);
        std.debug.print("p5c3d observer failed: {s}; report={s}\n", .{ @errorName(err), diagnostic });
        return err;
    };
    if (observer.exit_code != 0) {
        const diagnostic = try readFile(allocator, report_path, 64 * 1024);
        defer allocator.free(diagnostic);
        std.debug.print("p5c3d observer exit={d}; report={s}\n", .{ observer.exit_code, diagnostic });
    }
    try std.testing.expectEqual(@as(c_int, 0), observer.exit_code);
    try std.testing.expect(observer.saw_marker);
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&observer.before),
        std.mem.asBytes(&observer.after),
    );

    const takeover = try runProductAttach(product, base, runtime_text, .takeover);
    try std.testing.expectEqual(@as(c_int, 5), takeover.exit_code);
    try legacy.sendInput(1, "after");
    try waitForCount(report_path, "input\n", 2);
    const report = try readFile(allocator, report_path, 64 * 1024);
    defer allocator.free(report);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, report, "runtime.attach.observer\n"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, report, "controller.takeover.UNEXPECTED\n"));
}

const AttachMode = enum { observer, takeover };
const AttachResult = struct { exit_code: c_int, saw_marker: bool, before: c.termios, after: c.termios };

fn runProductAttach(product: []const u8, session_host_root: [:0]const u8, runtime_id: [:0]const u8, mode: AttachMode) !AttachResult {
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.OpenPtyFailed;
    master = try moveAboveStdio(master);
    slave = try moveAboveStdio(slave);
    var initial_window = posix.winsize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    if (c.ioctl(slave, darwin_tiocswinsz, &initial_window) != 0)
        return error.WindowSizeFailed;
    defer _ = c.close(master);
    defer _ = c.close(slave);
    var before: c.termios = undefined;
    if (c.tcgetattr(slave, &before) != 0) return error.TermiosFailed;
    var env_buf: [320]u8 = undefined;
    const env_arg = try std.fmt.bufPrintZ(&env_buf, "MARU_SESSION_HOST_ROOT={s}", .{session_host_root});
    var product_buf: [1024]u8 = undefined;
    const product_z = try std.fmt.bufPrintZ(&product_buf, "{s}", .{product});
    const child = c.fork();
    if (child < 0) return error.ForkFailed;
    if (child == 0) {
        _ = c.dup2(slave, 0);
        _ = c.dup2(slave, 1);
        _ = c.dup2(slave, 2);
        _ = c.close(master);
        _ = c.close(slave);
        const argv_observer = [_:null]?[*:0]const u8{ "env", env_arg.ptr, product_z.ptr, "attach", "--read-only", runtime_id.ptr };
        const argv_takeover = [_:null]?[*:0]const u8{ "env", env_arg.ptr, product_z.ptr, "attach", "--take-over", runtime_id.ptr };
        _ = c.execve("/usr/bin/env", if (mode == .observer) &argv_observer else &argv_takeover, @ptrCast(c.environ));
        c._exit(127);
    }
    var output: [64 * 1024]u8 = undefined;
    var used: usize = 0;
    var sent_detach = mode == .takeover;
    const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    var status: c_int = undefined;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds - started < process_deadline_ns) {
        var poll_fds = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&poll_fds, 20) catch 0;
        if (poll_fds[0].revents & posix.POLL.IN != 0 and used < output.len) {
            const count = c.read(master, output[used..].ptr, output.len - used);
            if (count > 0) used += @intCast(count);
        }
        if (!sent_detach and std.mem.indexOf(u8, output[0..used], "x") != null) {
            const chord = [_]u8{ 0x1c, 'd' };
            try writeAll(master, &chord);
            sent_detach = true;
        }
        const waited = c.waitpid(child, &status, c.W.NOHANG);
        if (waited == child) {
            while (used < output.len) {
                var drain_fds = [_]posix.pollfd{.{ .fd = master, .events = posix.POLL.IN, .revents = 0 }};
                _ = posix.poll(&drain_fds, 0) catch break;
                if (drain_fds[0].revents & posix.POLL.IN == 0) break;
                const count = c.read(master, output[used..].ptr, output.len - used);
                if (count > 0) {
                    used += @intCast(count);
                    continue;
                }
                break;
            }
            var after: c.termios = undefined;
            if (c.tcgetattr(slave, &after) != 0) return error.TermiosFailed;
            const unsigned: u32 = @bitCast(status);
            if (!c.W.IFEXITED(unsigned) or c.W.EXITSTATUS(unsigned) != 0)
                std.debug.print("p5c3d attach {s} output={s}\n", .{ @tagName(mode), output[0..used] });
            return .{
                .exit_code = if (c.W.IFEXITED(unsigned)) @intCast(c.W.EXITSTATUS(unsigned)) else -1,
                .saw_marker = std.mem.indexOf(u8, output[0..used], "x") != null,
                .before = before,
                .after = after,
            };
        }
        if (waited < 0 and posix.errno(waited) != .INTR) return error.WaitFailed;
    }
    std.debug.print("p5c3d attach {s} deadline output={s}\n", .{ @tagName(mode), output[0..used] });
    killAndReap(child);
    return error.DeadlineExceeded;
}

fn writeSnapshot(allocator: std.mem.Allocator, path: [:0]const u8) !void {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(allocator);
    const meta = try session_host.screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 1, .rows = 1, .cursor = .{} });
    defer allocator.free(meta);
    try session_host.screen_stream.appendRecord(&bytes, allocator, meta);
    var runs = [_]session_host.screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try session_host.screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = 1 }, .{ .row_index = 0, .runs = &runs });
    defer allocator.free(row);
    try session_host.screen_stream.appendRecord(&bytes, allocator, row);
    try writeFile(path, bytes.items);
}

fn verifyFrozenSource(allocator: std.mem.Allocator) !void {
    const source = try readFile(allocator, "tests/fixtures/session_host_pre_p5b3_v2.zig", 2 * 1024 * 1024);
    defer allocator.free(source);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(provenance.source_sha256, &hex);
    try std.testing.expectEqualStrings("a9ed24855f6261303d6f467203bcfed183f27175", provenance.source_revision);
    try std.testing.expectEqualStrings("mrsh-v2:screen-v2:controller-transfer-absent", provenance.expected_fingerprint);
}

fn spawnFixture(fixture: []const u8, socket: [:0]const u8, host: [:0]const u8, runtime: [:0]const u8, snapshot: [:0]const u8, report: [:0]const u8, owner: [:0]const u8, build_id: [:0]const u8) !c.pid_t {
    var fixture_buf: [1024]u8 = undefined;
    const fixture_z = try std.fmt.bufPrintZ(&fixture_buf, "{s}", .{fixture});
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ fixture_z.ptr, socket.ptr, host.ptr, runtime.ptr, snapshot.ptr, report.ptr, owner.ptr, build_id.ptr };
        _ = c.execve(fixture_z.ptr, &argv, @ptrCast(c.environ));
        c._exit(127);
    }
    return pid;
}

fn waitForText(path: [:0]const u8, needle: []const u8) !void {
    return waitForCount(path, needle, 1);
}
fn waitForCount(path: [:0]const u8, needle: []const u8, wanted: usize) !void {
    const started = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    while (std.Io.Clock.awake.now(std.testing.io).nanoseconds - started < deadline_ns) {
        const bytes = readFile(std.testing.allocator, path, 64 * 1024) catch {
            _ = usleep(10 * 1000);
            continue;
        };
        defer std.testing.allocator.free(bytes);
        if (std.mem.count(u8, bytes, needle) >= wanted) return;
        _ = usleep(10 * 1000);
    }
    return error.DeadlineExceeded;
}

fn mkdirExact(path: [:0]const u8) !void {
    if (c.mkdir(path.ptr, 0o700) != 0) return error.MkdirFailed;
}
fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    try writeAll(fd, bytes);
}
fn readFile(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}
fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        if (rc <= 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}
fn moveAboveStdio(fd: c.fd_t) !c.fd_t {
    if (fd > 2) return fd;
    const moved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (moved < 0) return error.FcntlFailed;
    _ = c.close(fd);
    return moved;
}
fn killAndReap(pid: c.pid_t) void {
    _ = c.kill(pid, .KILL);
    var status: c_int = undefined;
    while (c.waitpid(pid, &status, 0) < 0 and posix.errno(-1) == .INTR) {}
}
