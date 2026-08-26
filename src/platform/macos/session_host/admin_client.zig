//! Public admin CLI의 existing-current-host connector.
//! Secure manifest registry를 읽기만 하며 host spawn, lock acquisition, manifest publication을 하지 않는다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const discovery = @import("discovery.zig");
const host_manifest = @import("host_manifest.zig");
const protocol = @import("protocol.zig");
const recovery_discovery = @import("recovery_discovery.zig");
const screen_stream = @import("maru").session.screen_stream;
const short_endpoint = @import("short_endpoint.zig");
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn openpty(
    amaster: *c.fd_t,
    aslave: *c.fd_t,
    name: ?[*]u8,
    termp: ?*anyopaque,
    winp: ?*posix.winsize,
) c_int;

pub const Unavailable = enum {
    absent,
    ambiguous,
    denied,
    unsupported,
    busy,
    transient,
    protocol_error,
    out_of_memory,
};

pub const Outcome = union(enum) {
    connected: client_mod.Client,
    unavailable: Unavailable,
};

const Candidate = struct {
    host_id: u128,
    protocol_major: u16,
    screen_codec_version: u16,
    build_id: []const u8,
};

const Selection = union(enum) {
    none,
    one: usize,
    multiple,
};

fn selectCurrent(candidates: []const Candidate, build_id: []const u8) Selection {
    var selected: ?usize = null;
    for (candidates, 0..) |candidate, index| {
        if (candidate.protocol_major != protocol.version_major or
            candidate.screen_codec_version != screen_stream.codec_version or
            !std.mem.eql(u8, candidate.build_id, build_id))
            continue;
        if (selected != null) return .multiple;
        selected = index;
    }
    return if (selected) |index| .{ .one = index } else .none;
}

pub fn connectCurrent(
    allocator: std.mem.Allocator,
    executable_path: [:0]const u8,
    base_cache_dir: []const u8,
) Outcome {
    var dir_buf: [512]u8 = undefined;
    const session_dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .unavailable = .denied };
    const build_id = host_manifest.buildIdForExecutable(allocator, executable_path) catch |err|
        return .{ .unavailable = if (err == error.OutOfMemory) .out_of_memory else .denied };
    defer allocator.free(build_id);
    host_manifest.validateRegistryRoot(session_dir) catch |err| return .{
        .unavailable = if (err == error.ManifestNotFound) .absent else .denied,
    };
    var found = recovery_discovery.discover(allocator, session_dir);
    defer found.deinit(allocator);
    const entries = switch (found) {
        .unavailable => |reason| return .{
            .unavailable = switch (reason) {
                .out_of_memory => .out_of_memory,
                // Root는 바로 위에서 secure하게 존재 검증했다. 이후 열거 실패는 absence가 아니라
                // permission/authority race 또는 I/O 실패이므로 fail-closed denied다.
                .registry_unavailable => .denied,
                .too_many_hosts => .ambiguous,
            },
        },
        .complete => |items| items,
    };
    var candidates: std.ArrayListUnmanaged(Candidate) = .empty;
    defer candidates.deinit(allocator);
    for (entries) |entry| switch (entry) {
        .unavailable => {},
        .candidate => |candidate| candidates.append(allocator, .{
            .host_id = candidate.manifest.host_id,
            .protocol_major = candidate.manifest.protocol_major,
            .screen_codec_version = candidate.manifest.screen_codec_version,
            .build_id = candidate.manifest.build_id,
        }) catch return .{ .unavailable = .out_of_memory },
    };
    const selected = switch (selectCurrent(candidates.items, build_id)) {
        .none => return .{ .unavailable = .absent },
        .multiple => return .{ .unavailable = .ambiguous },
        .one => |index| index,
    };
    const selected_id = candidates.items[selected].host_id;
    var manifest: ?*const host_manifest.Manifest = null;
    for (entries) |*entry| switch (entry.*) {
        .unavailable => {},
        .candidate => |*candidate| if (candidate.manifest.host_id == selected_id) {
            manifest = &candidate.manifest;
            break;
        },
    };
    const exact = manifest orelse return .{ .unavailable = .protocol_error };
    const endpoint = allocator.dupeZ(u8, exact.endpoint) catch
        return .{ .unavailable = .out_of_memory };
    defer allocator.free(endpoint);
    var client = client_mod.Client.connectAdmin(allocator, endpoint) catch |err|
        return .{
            .unavailable = switch (err) {
                // exact ready manifest와 live lease를 고른 뒤 endpoint가 사라진 것은 discovery absence가
                // 아니라 TOCTOU/transport race다.
                error.EndpointAbsent => .transient,
                error.EndpointDenied => .denied,
                error.EndpointTransient => .transient,
                error.IncompatibleVersion => .unsupported,
                error.AdminBusy => .busy,
                error.Unauthorized => .denied,
                error.OutOfMemory => .out_of_memory,
                else => .protocol_error,
            },
        };
    if (client.host_id != exact.host_id or
        client.wire_major != exact.protocol_major or
        client.screen_codec_version != exact.screen_codec_version or
        client.upgrade_epoch != exact.upgrade_epoch or
        client.build_id == null or !std.mem.eql(u8, client.build_id.?, exact.build_id) or
        !std.mem.eql(u8, client.lifecycle, @tagName(exact.lifecycle)))
    {
        client.deinit();
        return .{ .unavailable = .protocol_error };
    }
    return .{ .connected = client };
}

test "admin current-host selection is exact and rejects ambiguity" {
    const current = Candidate{
        .host_id = 1,
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .build_id = "sha256:current",
    };
    const old = Candidate{
        .host_id = 2,
        .protocol_major = protocol.version_major - 1,
        .screen_codec_version = 1,
        .build_id = "sha256:old",
    };
    try std.testing.expect(selectCurrent(&.{}, "sha256:current") == .none);
    try std.testing.expectEqual(@as(usize, 0), selectCurrent(&.{ current, old }, "sha256:current").one);
    try std.testing.expect(selectCurrent(&.{ current, current }, "sha256:current") == .multiple);
}

const ProductResult = struct {
    exit_code: c_int,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *ProductResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

const ControlledProductCli = struct {
    pid: c.pid_t,
    master: c.fd_t,
    stdout_fd: c.fd_t,
    stderr_fd: c.fd_t,

    fn closeMaster(self: *ControlledProductCli) void {
        closeOwnedFd(&self.master);
    }

    fn cleanup(self: *ControlledProductCli, io: std.Io) void {
        if (self.pid > 0) {
            var status: c_int = 0;
            while (true) {
                const waited = c.waitpid(self.pid, &status, c.W.NOHANG);
                if (waited == self.pid or (waited < 0 and posix.errno(waited) == .CHILD)) {
                    self.pid = -1;
                    break;
                }
                if (waited < 0 and posix.errno(waited) == .INTR) continue;
                if (waited < 0) {
                    self.pid = -1;
                    break;
                }
                break;
            }
            if (self.pid > 0) {
                _ = c.kill(self.pid, posix.SIG.KILL);
                const started = std.Io.Timestamp.now(io, .awake);
                while (started.untilNow(io, .awake).toMilliseconds() < 10_000) {
                    const waited = c.waitpid(self.pid, &status, c.W.NOHANG);
                    if (waited == self.pid or (waited < 0 and posix.errno(waited) == .CHILD)) break;
                    if (waited < 0 and posix.errno(waited) != .INTR) break;
                    _ = usleep(10_000);
                }
                self.pid = -1;
            }
        }
        self.closeMaster();
        closeOwnedFd(&self.stdout_fd);
        closeOwnedFd(&self.stderr_fd);
    }
};

fn closeOwnedFd(fd: *c.fd_t) void {
    if (fd.* >= 0) {
        _ = c.close(fd.*);
        fd.* = -1;
    }
}

fn setNonblocking(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nonblocking) < 0)
        return error.TestUnexpectedResult;
}

fn drainProductFd(
    allocator: std.mem.Allocator,
    fd: *c.fd_t,
    output: *std.ArrayList(u8),
) !void {
    if (fd.* < 0) return;
    var buf: [4096]u8 = undefined;
    while (true) {
        const count = c.read(fd.*, &buf, buf.len);
        if (count > 0) {
            try output.appendSlice(allocator, buf[0..@intCast(count)]);
            if (output.items.len > 64 * 1024) return error.TestUnexpectedResult;
            continue;
        }
        if (count == 0) {
            closeOwnedFd(fd);
            return;
        }
        return switch (posix.errno(count)) {
            .INTR => continue,
            .AGAIN => {},
            else => error.TestUnexpectedResult,
        };
    }
}

fn collectProductProcess(
    io: std.Io,
    allocator: std.mem.Allocator,
    process: *ControlledProductCli,
    stderr_prefix: []const u8,
) !ProductResult {
    try setNonblocking(process.stdout_fd);
    try setNonblocking(process.stderr_fd);
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);
    try stderr_list.appendSlice(allocator, stderr_prefix);
    const started = std.Io.Timestamp.now(io, .awake);
    var status: c_int = 0;
    var reaped = false;

    while (!reaped or process.stdout_fd >= 0 or process.stderr_fd >= 0) {
        if (!reaped) {
            const waited = c.waitpid(process.pid, &status, c.W.NOHANG);
            if (waited == process.pid) {
                reaped = true;
                process.pid = -1;
                process.closeMaster();
            } else if (waited < 0 and posix.errno(waited) != .INTR) {
                return error.TestUnexpectedResult;
            }
        }
        try drainProductFd(allocator, &process.stdout_fd, &stdout_list);
        try drainProductFd(allocator, &process.stderr_fd, &stderr_list);
        if (reaped and process.stdout_fd < 0 and process.stderr_fd < 0) break;

        const elapsed = started.untilNow(io, .awake).toMilliseconds();
        if (elapsed >= 10_000) return error.TestUnexpectedResult;
        var fds = [_]posix.pollfd{
            .{ .fd = process.stdout_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = process.stderr_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const remaining: i64 = 10_000 - elapsed;
        const timeout: i32 = @intCast(@min(remaining, 50));
        _ = posix.poll(&fds, timeout) catch return error.TestUnexpectedResult;
    }

    const stdout = try stdout_list.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try stderr_list.toOwnedSlice(allocator);
    return .{
        .exit_code = blk: {
            const unsigned: u32 = @bitCast(status);
            break :blk if (c.W.IFEXITED(unsigned)) @intCast(c.W.EXITSTATUS(unsigned)) else -1;
        },
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn runProductCli(
    allocator: std.mem.Allocator,
    product_exe: [:0]const u8,
    session_host_root: [:0]const u8,
    args: []const [:0]const u8,
) !ProductResult {
    return runProductCliInput(allocator, product_exe, session_host_root, args);
}

fn runProductCliTtyInput(
    allocator: std.mem.Allocator,
    product_exe: [:0]const u8,
    session_host_root: [:0]const u8,
    args: []const [:0]const u8,
    input: []const u8,
) !ProductResult {
    var process = try startControlledProductCli(allocator, product_exe, session_host_root, args);
    defer process.cleanup(std.testing.io);
    var offset: usize = 0;
    while (offset < input.len) {
        const written = c.write(process.master, input.ptr + offset, input.len - offset);
        if (written < 0) {
            if (posix.errno(written) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        offset += @intCast(written);
    }
    return collectProductProcess(std.testing.io, allocator, &process, "");
}

fn runProductCliInput(
    allocator: std.mem.Allocator,
    product_exe: [:0]const u8,
    session_host_root: [:0]const u8,
    args: []const [:0]const u8,
) !ProductResult {
    var pipes_transferred = false;
    var stdout_fds: [2]c_int = undefined;
    var stderr_fds: [2]c_int = undefined;
    if (c.pipe(&stdout_fds) != 0) return error.TestUnexpectedResult;
    errdefer if (!pipes_transferred) {
        _ = c.close(stdout_fds[0]);
        _ = c.close(stdout_fds[1]);
    };
    if (c.pipe(&stderr_fds) != 0) {
        return error.TestUnexpectedResult;
    }
    errdefer if (!pipes_transferred) {
        _ = c.close(stderr_fds[0]);
        _ = c.close(stderr_fds[1]);
    };
    const env_arg = try std.fmt.allocPrintSentinel(
        allocator,
        "MARU_SESSION_HOST_ROOT={s}",
        .{session_host_root},
        0,
    );
    defer allocator.free(env_arg);
    var argv: [8:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 8;
    argv[0] = "env";
    argv[1] = env_arg.ptr;
    argv[2] = product_exe.ptr;
    for (args, 0..) |arg, index| argv[index + 3] = arg.ptr;
    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = c.dup2(stdout_fds[1], 1);
        _ = c.dup2(stderr_fds[1], 2);
        _ = c.close(stdout_fds[0]);
        _ = c.close(stdout_fds[1]);
        _ = c.close(stderr_fds[0]);
        _ = c.close(stderr_fds[1]);
        _ = c.execve("/usr/bin/env", &argv, @ptrCast(c.environ));
        c._exit(127);
    }
    _ = c.close(stdout_fds[1]);
    _ = c.close(stderr_fds[1]);
    var process: ControlledProductCli = .{
        .pid = pid,
        .master = -1,
        .stdout_fd = stdout_fds[0],
        .stderr_fd = stderr_fds[0],
    };
    pipes_transferred = true;
    defer process.cleanup(std.testing.io);
    return collectProductProcess(std.testing.io, allocator, &process, "");
}

fn startControlledProductCli(
    allocator: std.mem.Allocator,
    product_exe: [:0]const u8,
    session_host_root: [:0]const u8,
    args: []const [:0]const u8,
) !ControlledProductCli {
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    if (openpty(&master, &slave, null, null, null) != 0) return error.TestUnexpectedResult;
    errdefer _ = c.close(master);
    errdefer _ = c.close(slave);
    var stdout_fds: [2]c_int = undefined;
    var stderr_fds: [2]c_int = undefined;
    if (c.pipe(&stdout_fds) != 0) return error.TestUnexpectedResult;
    errdefer {
        _ = c.close(stdout_fds[0]);
        _ = c.close(stdout_fds[1]);
    }
    if (c.pipe(&stderr_fds) != 0) return error.TestUnexpectedResult;
    errdefer {
        _ = c.close(stderr_fds[0]);
        _ = c.close(stderr_fds[1]);
    }
    const env_arg = try std.fmt.allocPrintSentinel(
        allocator,
        "MARU_SESSION_HOST_ROOT={s}",
        .{session_host_root},
        0,
    );
    defer allocator.free(env_arg);
    var argv: [8:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 8;
    argv[0] = "env";
    argv[1] = env_arg.ptr;
    argv[2] = product_exe.ptr;
    for (args, 0..) |arg, index| argv[index + 3] = arg.ptr;
    const pid = c.fork();
    if (pid < 0) return error.TestUnexpectedResult;
    if (pid == 0) {
        _ = c.dup2(slave, 0);
        _ = c.dup2(stdout_fds[1], 1);
        _ = c.dup2(stderr_fds[1], 2);
        _ = c.close(master);
        _ = c.close(slave);
        _ = c.close(stdout_fds[0]);
        _ = c.close(stdout_fds[1]);
        _ = c.close(stderr_fds[0]);
        _ = c.close(stderr_fds[1]);
        _ = c.execve("/usr/bin/env", &argv, @ptrCast(c.environ));
        c._exit(127);
    }
    _ = c.close(slave);
    _ = c.close(stdout_fds[1]);
    _ = c.close(stderr_fds[1]);
    return .{
        .pid = pid,
        .master = master,
        .stdout_fd = stdout_fds[0],
        .stderr_fd = stderr_fds[0],
    };
}

fn readUntilPrompt(
    io: std.Io,
    allocator: std.mem.Allocator,
    fd: c.fd_t,
) ![]u8 {
    const started = std.Io.Timestamp.now(io, .awake);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var bytes: [1024]u8 = undefined;
    while (std.mem.indexOf(u8, output.items, "? [y/N] ") == null) {
        const elapsed = started.untilNow(io, .awake).toMilliseconds();
        if (elapsed >= 10_000) return error.TestUnexpectedResult;
        var fds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = posix.poll(&fds, @intCast(10_000 - elapsed)) catch
            return error.TestUnexpectedResult;
        if (ready != 1 or fds[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0)
            return error.TestUnexpectedResult;
        const count = c.read(fd, &bytes, bytes.len);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (count == 0) return error.TestUnexpectedResult;
        try output.appendSlice(allocator, bytes[0..@intCast(count)]);
        if (output.items.len > 64 * 1024) return error.TestUnexpectedResult;
    }
    return output.toOwnedSlice(allocator);
}

fn finishControlledProductCli(
    allocator: std.mem.Allocator,
    process: *ControlledProductCli,
    stderr_prefix: []const u8,
) !ProductResult {
    return collectProductProcess(std.testing.io, allocator, process, stderr_prefix);
}

/// `session_host_root` 는 이 테스트가 정한 **자기 격리 뿌리**다(pid+nonce). 호출부는 socket 경로도 반드시
/// 같은 뿌리에서 만들어야 한다(`socketPathUnder`) — 예전에는 registry 만 이 root 로 옮기고 socket 은 uid 로
/// 따로 계산해, 둘이 갈렸는데도 **우연히 양쪽 다 공용 `/tmp/maru-<uid>` 라서** 맞아떨어졌다. 그 우연이
/// 통과의 이유이자 사용자 registry 오염의 이유였다.
fn spawnProductHost(
    product_exe: [*:0]const u8,
    session_host_root: [:0]const u8,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_text: [:0]const u8,
) !c.pid_t {
    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        var env_buf: [320]u8 = undefined;
        const env_arg = std.fmt.bufPrintZ(&env_buf, "MARU_SESSION_HOST_ROOT={s}", .{session_host_root}) catch c._exit(127);
        const argv = [_:null]?[*:0]const u8{
            "env",
            "-u",
            "MARU_SESSION_HOST_TEST_ONESHOT",
            env_arg.ptr,
            product_exe,
            "__session-host",
            session_dir.ptr,
            socket_path.ptr,
            host_text.ptr,
        };
        _ = c.execve("/usr/bin/env", &argv, @ptrCast(c.environ));
        c._exit(127);
    }
    return child;
}

fn waitProductHostReady(
    allocator: std.mem.Allocator,
    session_dir: [:0]const u8,
    host_id: u128,
) !void {
    for (0..150) |_| {
        var manifest = host_manifest.load(allocator, session_dir, host_id) catch {
            _ = usleep(20 * 1000);
            continue;
        };
        manifest.deinit();
        return;
    }
    return error.TestUnexpectedResult;
}

fn removeProductHostFiles(session_dir: [:0]const u8, socket_path: [:0]const u8, host_id: u128) void {
    _ = c.unlink(socket_path.ptr);
    var manifest_buf: [832]u8 = undefined;
    if (host_manifest.manifestPathIn(&manifest_buf, session_dir, host_id)) |path|
        _ = c.unlink(path.ptr)
    else |_| {}
    var owner_buf: [832]u8 = undefined;
    if (host_manifest.ownerLockPathIn(&owner_buf, session_dir, host_id)) |path|
        _ = c.unlink(path.ptr)
    else |_| {}
    var host_dir_buf: [768]u8 = undefined;
    if (host_manifest.hostDirPathIn(&host_dir_buf, session_dir, host_id)) |path|
        _ = c.rmdir(path.ptr)
    else |_| {}
}

const FileSnapshot = struct {
    dev: posix.dev_t,
    ino: posix.ino_t,
    size: u64,
    sha256: [32]u8,
};

fn snapshotFile(path: [:0]const u8) !FileSnapshot {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return error.TestUnexpectedResult;
    defer _ = c.close(fd);
    var stat: posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.size < 0) return error.TestUnexpectedResult;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var bytes: [4096]u8 = undefined;
    while (true) {
        const read_len = c.read(fd, &bytes, bytes.len);
        if (read_len < 0) {
            if (posix.errno(read_len) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (read_len == 0) break;
        hasher.update(bytes[0..@intCast(read_len)]);
        total += @intCast(read_len);
    }
    if (total != @as(u64, @intCast(stat.size))) return error.TestUnexpectedResult;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .dev = stat.dev, .ino = stat.ino, .size = total, .sha256 = digest };
}

test "product read CLI connects to an existing daemon without spawning and emits stable JSON" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const required = std.c.getenv("MARU_SESSION_HOST_REQUIRE_PRODUCT_LAUNCH_SMOKE") orelse
        return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(required), "maru-test-only-v1"))
        return error.SkipZigTest;
    const product_raw = std.c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse
        return error.TestUnexpectedResult;
    const product_exe = std.mem.span(product_raw);
    const allocator = std.testing.allocator;
    const product_z = try allocator.dupeZ(u8, product_exe);
    defer allocator.free(product_z);
    const pid_bits: u128 = @intCast(c.getpid());
    // 실패로 남은 /tmp fixture와 PID가 재사용돼도 다음 run이 과거 hosts/socket을 자기 것으로 오인하지 않게
    // 경로와 host id가 같은 per-run nonce를 공유한다. PID 단독 격리는 장시간 반복/CI worker에서 충분하지 않다.
    var nonce_raw: u64 = 0;
    std.c.arc4random_buf(std.mem.asBytes(&nonce_raw).ptr, @sizeOf(u64));
    const nonce = (nonce_raw & (std.math.maxInt(u64) >> 1)) | 1;
    const host_id = (pid_bits << 64) | nonce;
    var xdg_buf: [224]u8 = undefined;
    // registry 를 이 프로세스만의 자리로 돌린다 — 안 그러면 테스트가 **사용자의 진짜 세션**과
    // 같은 registry 를 쓴다(base 가 uid 로 고정이라 그렇다).
    const xdg = try std.fmt.bufPrintZ(
        &xdg_buf,
        "/tmp/maru-admin-cli-{d}-{x}",
        .{ c.getpid(), nonce },
    );
    _ = c.mkdir(xdg.ptr, 0o700);
    // base 를 **이 프로세스의 격리 root** 로 통일한다. registry(`{base}/session-host`)·socket(`{base}/sh`)·
    // 자식에게 넘기는 `MARU_SESSION_HOST_ROOT` 가 전부 한 뿌리를 보게 하는 것이 핵심이다 — 뿌리가 갈리면
    // 자식이 bind 한 socket 을 부모가 못 찾는다(그 상태로 `waitProductHostReady` 가 타임아웃한다).
    //
    // 예전에는 여기서 `{xdg}/maru` 를 썼는데, 그때는 socket 이 uid 로 고정이라 registry 만 옮겨졌고 socket 은
    // 사용자의 공용 `/tmp/maru-<uid>/sh` 로 새어 나갔다. 이제 socket 도 root 를 따르므로 뿌리를 하나로 맞춘다.
    // per-run 충돌은 `host_id` 의 nonce 가 이미 막고 있고, root 자체도 test runner 가 pid 로 갈라 준다.
    var base_buf: [256]u8 = undefined;
    const base = try short_endpoint.currentUserRootPathIn(&base_buf);
    try short_endpoint.prepareCurrentUserNamespace();
    var session_buf: [320]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    _ = c.mkdir(session_dir.ptr, 0o700);
    try short_endpoint.prepareCurrentUserNamespace();
    var socket_buf: [128]u8 = undefined;
    const socket_path = try short_endpoint.currentSocketPathIn(&socket_buf, host_id);
    var host_buf: [33]u8 = undefined;
    const host_text = try std.fmt.bufPrintZ(&host_buf, "{x:0>32}", .{host_id});

    var absent = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer absent.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 3), absent.exit_code);
    try std.testing.expectEqual(@as(usize, 0), absent.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, absent.stderr, "\n"));
    var hosts_root_buf: [640]u8 = undefined;
    const hosts_root = try host_manifest.hostsRootPathIn(&hosts_root_buf, session_dir);
    var absent_stat: posix.Stat = undefined;
    const absent_stat_rc = c.fstatat(posix.AT.FDCWD, hosts_root.ptr, &absent_stat, posix.AT.SYMLINK_NOFOLLOW);
    try std.testing.expect(absent_stat_rc != 0);
    try std.testing.expectEqual(posix.E.NOENT, posix.errno(absent_stat_rc));

    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(hosts_root.ptr, 0o700));
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(hosts_root.ptr, 0o777));
    var denied = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer denied.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 4), denied.exit_code);
    try std.testing.expectEqual(@as(usize, 0), denied.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, denied.stderr, "\n"));
    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(hosts_root.ptr));

    var usage = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", "aabb" },
    );
    defer usage.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 2), usage.exit_code);
    try std.testing.expectEqual(@as(usize, 0), usage.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, usage.stderr, "usage:") != null);

    var non_tty_end = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", "000000000000000000000000000000aa" },
    );
    defer non_tty_end.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 2), non_tty_end.exit_code);
    try std.testing.expectEqual(@as(usize, 0), non_tty_end.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, non_tty_end.stderr, "usage:") != null);

    const child = try spawnProductHost(product_raw, base, session_dir, socket_path, host_text);
    var child_active = true;
    defer {
        if (child_active) {
            _ = c.kill(child, posix.SIG.TERM);
            var status: c_int = 0;
            _ = c.waitpid(child, &status, 0);
            removeProductHostFiles(session_dir, socket_path, host_id);
        }
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, session_dir)) |path|
            _ = c.rmdir(path.ptr)
        else |_| {}
        _ = c.rmdir(session_dir.ptr);
        // base 는 이제 이 프로세스 공용 격리 root 다 — 뒤따르는 테스트가 계속 쓰므로 지우지 않는다.
        _ = c.rmdir(xdg.ptr);
    }
    try waitProductHostReady(allocator, session_dir, host_id);
    var ready_manifest = try host_manifest.load(allocator, session_dir, host_id);
    defer ready_manifest.deinit();
    var manifest_path_buf: [832]u8 = undefined;
    const manifest_path = try host_manifest.manifestPathIn(&manifest_path_buf, session_dir, host_id);
    var owner_path_buf: [832]u8 = undefined;
    const owner_path = try host_manifest.ownerLockPathIn(&owner_path_buf, session_dir, host_id);
    const manifest_before = try snapshotFile(manifest_path);
    const owner_before = try snapshotFile(owner_path);
    var launch_path_buf: [512]u8 = undefined;
    const launch_path = try discovery.lockPathIn(&launch_path_buf, session_dir);
    var launch_stat: posix.Stat = undefined;
    try std.testing.expect(c.fstatat(
        posix.AT.FDCWD,
        launch_path.ptr,
        &launch_stat,
        posix.AT.SYMLINK_NOFOLLOW,
    ) != 0);
    var status_result = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer status_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), status_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), status_result.stderr.len);
    const expected_status = try std.fmt.allocPrint(
        allocator,
        "{{\"host_id\":\"{s}\",\"build_id\":\"{s}\",\"protocol_major\":{d},\"screen_codec_version\":{d},\"upgrade_epoch\":{d},\"authority_generation\":1,\"lifecycle\":\"ready\",\"runtime_count\":0,\"client_count\":1}}\n",
        .{
            host_text,
            ready_manifest.build_id,
            protocol.version_major,
            screen_stream.codec_version,
            ready_manifest.upgrade_epoch,
        },
    );
    defer allocator.free(expected_status);
    try std.testing.expectEqualStrings(expected_status, status_result.stdout);

    const second_host_id = host_id + 1;
    var second_socket_buf: [128]u8 = undefined;
    const second_socket = try short_endpoint.currentSocketPathIn(&second_socket_buf, second_host_id);
    var second_host_buf: [33]u8 = undefined;
    const second_host_text = try std.fmt.bufPrintZ(&second_host_buf, "{x:0>32}", .{second_host_id});
    const second_child = try spawnProductHost(
        product_raw,
        base,
        session_dir,
        second_socket,
        second_host_text,
    );
    var second_active = true;
    defer if (second_active) {
        _ = c.kill(second_child, posix.SIG.TERM);
        var status: c_int = 0;
        _ = c.waitpid(second_child, &status, 0);
        removeProductHostFiles(session_dir, second_socket, second_host_id);
    };
    try waitProductHostReady(allocator, session_dir, second_host_id);
    var ambiguous = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer ambiguous.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 8), ambiguous.exit_code);
    try std.testing.expectEqual(@as(usize, 0), ambiguous.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ambiguous.stderr, "\n"));
    _ = c.kill(second_child, posix.SIG.TERM);
    var second_status: c_int = 0;
    try std.testing.expectEqual(second_child, c.waitpid(second_child, &second_status, 0));
    removeProductHostFiles(session_dir, second_socket, second_host_id);
    second_active = false;

    var held_admin = try client_mod.Client.connectAdmin(allocator, socket_path);
    var busy_result = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer busy_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 6), busy_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), busy_result.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, busy_result.stderr, "\n"));
    held_admin.deinit();

    var gui = try client_mod.Client.connect(allocator, socket_path, .gui);
    var gui_active = true;
    errdefer if (gui_active) gui.deinit();
    const spawn_response = try gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":80,\"rows\":24}",
    );
    defer allocator.free(spawn_response);
    const SpawnWire = struct { result: struct { runtime_id: []const u8 } };
    var spawn = try std.json.parseFromSlice(SpawnWire, allocator, spawn_response, .{});
    defer spawn.deinit();
    const runtime_id = try allocator.dupeZ(u8, spawn.value.result.runtime_id);
    defer allocator.free(runtime_id);

    var list_result = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "list", "--json" },
    );
    defer list_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), list_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), list_result.stderr.len);
    const expected_list = try std.fmt.allocPrint(
        allocator,
        "{{\"runtimes\":[{{\"runtime_id\":\"{s}\",\"cols\":80,\"rows\":24,\"resize_generation\":0,\"has_controller\":false,\"observer_count\":0}}]}}\n",
        .{runtime_id},
    );
    defer allocator.free(expected_list);
    try std.testing.expectEqualStrings(expected_list, list_result.stdout);

    var list_text = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "list" },
    );
    defer list_text.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), list_text.exit_code);
    try std.testing.expectEqual(@as(usize, 0), list_text.stderr.len);
    const expected_text = try std.fmt.allocPrint(
        allocator,
        "{s}  80x24  controller=no  observers=0  resize-generation=0\n",
        .{runtime_id},
    );
    defer allocator.free(expected_text);
    try std.testing.expectEqualStrings(expected_text, list_text.stdout);

    var get_result = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", runtime_id, "--json" },
    );
    defer get_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), get_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), get_result.stderr.len);
    const expected_get = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"cols\":80,\"rows\":24,\"resize_generation\":0,\"has_controller\":false,\"observer_count\":0}}\n",
        .{runtime_id},
    );
    defer allocator.free(expected_get);
    try std.testing.expectEqualStrings(expected_get, get_result.stdout);

    var missing_result = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", "ffffffffffffffffffffffffffffffff", "--json" },
    );
    defer missing_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 7), missing_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), missing_result.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, missing_result.stderr, "\n"));

    var with_gui = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer with_gui.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), with_gui.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, with_gui.stdout, "\"runtime_count\":1,\"client_count\":2") != null);
    gui.deinit();
    gui_active = false;

    var after_gui = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "host", "status", "--json" },
    );
    defer after_gui.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), after_gui.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, after_gui.stdout, "\"runtime_count\":1,\"client_count\":1") != null);

    var end_gui = try client_mod.Client.connect(allocator, socket_path, .gui);
    defer end_gui.deinit();
    const end_spawn_response = try end_gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":100,\"rows\":30}",
    );
    defer allocator.free(end_spawn_response);
    var end_spawn = try std.json.parseFromSlice(SpawnWire, allocator, end_spawn_response, .{});
    defer end_spawn.deinit();
    const ended_runtime_id = try allocator.dupeZ(u8, end_spawn.value.result.runtime_id);
    defer allocator.free(ended_runtime_id);
    var ended = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", ended_runtime_id, "--yes" },
    );
    defer ended.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), ended.exit_code);
    try std.testing.expectEqual(@as(usize, 0), ended.stderr.len);
    const expected_ended = try std.fmt.allocPrint(allocator, "Ended runtime {s}.\n", .{ended_runtime_id});
    defer allocator.free(expected_ended);
    try std.testing.expectEqualStrings(expected_ended, ended.stdout);

    var ended_missing = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", ended_runtime_id, "--json" },
    );
    defer ended_missing.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 7), ended_missing.exit_code);
    var sibling_still_live = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", runtime_id, "--json" },
    );
    defer sibling_still_live.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), sibling_still_live.exit_code);

    const interactive_spawn_response = try end_gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":90,\"rows\":28}",
    );
    defer allocator.free(interactive_spawn_response);
    var interactive_spawn = try std.json.parseFromSlice(SpawnWire, allocator, interactive_spawn_response, .{});
    defer interactive_spawn.deinit();
    const interactive_runtime_id = try allocator.dupeZ(u8, interactive_spawn.value.result.runtime_id);
    defer allocator.free(interactive_runtime_id);
    const attach_params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"controller\",\"cols\":90,\"rows\":28}}",
        .{interactive_runtime_id},
    );
    defer allocator.free(attach_params);
    const attach_response = try end_gui.call("runtime.attach", attach_params);
    defer allocator.free(attach_response);
    try std.testing.expect(std.mem.indexOf(u8, attach_response, "\"input\":true") != null);

    var declined = try runProductCliTtyInput(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", interactive_runtime_id },
        "n\n",
    );
    defer declined.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 9), declined.exit_code);
    try std.testing.expectEqual(@as(usize, 0), declined.stdout.len);
    const expected_declined_stderr = try std.fmt.allocPrint(
        allocator,
        "End runtime {s} (90x28, controller=yes, observers=0)? [y/N] \nmaru: runtime was not ended\n",
        .{interactive_runtime_id},
    );
    defer allocator.free(expected_declined_stderr);
    try std.testing.expectEqualStrings(expected_declined_stderr, declined.stderr);
    var after_decline = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", interactive_runtime_id, "--json" },
    );
    defer after_decline.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), after_decline.exit_code);

    var confirmed = try runProductCliTtyInput(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", interactive_runtime_id },
        "yes\n",
    );
    defer confirmed.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), confirmed.exit_code);
    const expected_confirmed_stderr = try std.fmt.allocPrint(
        allocator,
        "End runtime {s} (90x28, controller=yes, observers=0)? [y/N] \n",
        .{interactive_runtime_id},
    );
    defer allocator.free(expected_confirmed_stderr);
    try std.testing.expectEqualStrings(expected_confirmed_stderr, confirmed.stderr);
    const expected_confirmed = try std.fmt.allocPrint(
        allocator,
        "Ended runtime {s}.\n",
        .{interactive_runtime_id},
    );
    defer allocator.free(expected_confirmed);
    try std.testing.expectEqualStrings(expected_confirmed, confirmed.stdout);

    const observer_spawn_response = try end_gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":88,\"rows\":26}",
    );
    defer allocator.free(observer_spawn_response);
    var observer_spawn = try std.json.parseFromSlice(SpawnWire, allocator, observer_spawn_response, .{});
    defer observer_spawn.deinit();
    const observer_runtime_id = try allocator.dupeZ(u8, observer_spawn.value.result.runtime_id);
    defer allocator.free(observer_runtime_id);
    var observer_gui = try client_mod.Client.connect(allocator, socket_path, .gui);
    defer observer_gui.deinit();
    const observer_params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\",\"mode\":\"observer\",\"cols\":88,\"rows\":26}}",
        .{observer_runtime_id},
    );
    defer allocator.free(observer_params);
    const observer_attach = try observer_gui.call("runtime.attach", observer_params);
    defer allocator.free(observer_attach);
    try std.testing.expect(std.mem.indexOf(u8, observer_attach, "\"observe\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, observer_attach, "\"input\":false") != null);
    var observer_ended = try runProductCliTtyInput(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", observer_runtime_id },
        "y\n",
    );
    defer observer_ended.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), observer_ended.exit_code);
    const expected_observer_stderr = try std.fmt.allocPrint(
        allocator,
        "End runtime {s} (88x26, controller=no, observers=1)? [y/N] \n",
        .{observer_runtime_id},
    );
    defer allocator.free(expected_observer_stderr);
    try std.testing.expectEqualStrings(expected_observer_stderr, observer_ended.stderr);

    const eof_spawn_response = try end_gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":72,\"rows\":22}",
    );
    defer allocator.free(eof_spawn_response);
    var eof_spawn = try std.json.parseFromSlice(SpawnWire, allocator, eof_spawn_response, .{});
    defer eof_spawn.deinit();
    const eof_runtime_id = try allocator.dupeZ(u8, eof_spawn.value.result.runtime_id);
    defer allocator.free(eof_runtime_id);
    var eof_process = try startControlledProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", eof_runtime_id },
    );
    defer eof_process.cleanup(std.testing.io);
    const eof_prompt = try readUntilPrompt(std.testing.io, allocator, eof_process.stderr_fd);
    defer allocator.free(eof_prompt);
    try std.testing.expectEqual(@as(isize, 3), c.write(eof_process.master, "yes", 3));
    eof_process.closeMaster();
    var eof_declined = try finishControlledProductCli(allocator, &eof_process, eof_prompt);
    defer eof_declined.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 9), eof_declined.exit_code);
    try std.testing.expectEqual(@as(usize, 0), eof_declined.stdout.len);
    const expected_eof_stderr = try std.fmt.allocPrint(
        allocator,
        "End runtime {s} (72x22, controller=no, observers=0)? [y/N] \nmaru: runtime was not ended\n",
        .{eof_runtime_id},
    );
    defer allocator.free(expected_eof_stderr);
    try std.testing.expectEqualStrings(expected_eof_stderr, eof_declined.stderr);
    var after_eof = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", eof_runtime_id, "--json" },
    );
    defer after_eof.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), after_eof.exit_code);

    var race_gui = try client_mod.Client.connect(allocator, socket_path, .gui);
    defer race_gui.deinit();
    const race_spawn_response = try race_gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":70,\"rows\":20}",
    );
    defer allocator.free(race_spawn_response);
    var race_spawn = try std.json.parseFromSlice(SpawnWire, allocator, race_spawn_response, .{});
    defer race_spawn.deinit();
    const race_runtime_id = try allocator.dupeZ(u8, race_spawn.value.result.runtime_id);
    defer allocator.free(race_runtime_id);
    var race_process = try startControlledProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", race_runtime_id },
    );
    defer race_process.cleanup(std.testing.io);
    const race_prompt = try readUntilPrompt(std.testing.io, allocator, race_process.stderr_fd);
    defer allocator.free(race_prompt);
    const race_terminate_params = try std.fmt.allocPrint(
        allocator,
        "{{\"runtime_id\":\"{s}\"}}",
        .{race_runtime_id},
    );
    defer allocator.free(race_terminate_params);
    const race_terminate = try race_gui.call("runtime.terminate", race_terminate_params);
    defer allocator.free(race_terminate);
    try std.testing.expect(std.mem.indexOf(u8, race_terminate, "\"terminated\":true") != null);
    try std.testing.expectEqual(@as(isize, 4), c.write(race_process.master, "yes\n", 4));
    var raced = try finishControlledProductCli(allocator, &race_process, race_prompt);
    defer raced.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 7), raced.exit_code);
    try std.testing.expectEqual(@as(usize, 0), raced.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, raced.stderr, "runtime_not_found") != null);

    try std.testing.expectEqualDeep(manifest_before, try snapshotFile(manifest_path));
    try std.testing.expectEqualDeep(owner_before, try snapshotFile(owner_path));
    try std.testing.expect(c.fstatat(
        posix.AT.FDCWD,
        launch_path.ptr,
        &launch_stat,
        posix.AT.SYMLINK_NOFOLLOW,
    ) != 0);

    // Preview authority is host-specific. A가 사라진 뒤 같은 current slot에 B가 나타나도 B에는 mutation request를
    // 보내지 않는다(runtime id 충돌 여부와 무관하게 opaque host_id가 먼저 gate한다).
    var swap_process = try startControlledProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "end", runtime_id },
    );
    defer swap_process.cleanup(std.testing.io);
    const swap_prompt = try readUntilPrompt(std.testing.io, allocator, swap_process.stderr_fd);
    defer allocator.free(swap_prompt);

    _ = c.kill(child, posix.SIG.TERM);
    var child_status: c_int = 0;
    try std.testing.expectEqual(child, c.waitpid(child, &child_status, 0));
    removeProductHostFiles(session_dir, socket_path, host_id);
    child_active = false;

    const replacement_host_id = host_id + 2;
    var replacement_socket_buf: [128]u8 = undefined;
    const replacement_socket = try short_endpoint.currentSocketPathIn(&replacement_socket_buf, replacement_host_id);
    var replacement_host_buf: [33]u8 = undefined;
    const replacement_host_text = try std.fmt.bufPrintZ(
        &replacement_host_buf,
        "{x:0>32}",
        .{replacement_host_id},
    );
    const replacement_child = try spawnProductHost(
        product_raw,
        base,
        session_dir,
        replacement_socket,
        replacement_host_text,
    );
    var replacement_active = true;
    defer if (replacement_active) {
        _ = c.kill(replacement_child, posix.SIG.TERM);
        var status: c_int = 0;
        _ = c.waitpid(replacement_child, &status, 0);
        removeProductHostFiles(session_dir, replacement_socket, replacement_host_id);
    };
    try waitProductHostReady(allocator, session_dir, replacement_host_id);
    var replacement_gui = try client_mod.Client.connect(allocator, replacement_socket, .gui);
    var replacement_gui_active = true;
    defer if (replacement_gui_active) replacement_gui.deinit();
    const replacement_spawn_response = try replacement_gui.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":64,\"rows\":18}",
    );
    defer allocator.free(replacement_spawn_response);
    var replacement_spawn = try std.json.parseFromSlice(SpawnWire, allocator, replacement_spawn_response, .{});
    defer replacement_spawn.deinit();
    const replacement_runtime_id = try allocator.dupeZ(u8, replacement_spawn.value.result.runtime_id);
    defer allocator.free(replacement_runtime_id);

    try std.testing.expectEqual(@as(isize, 4), c.write(swap_process.master, "yes\n", 4));
    var swapped = try finishControlledProductCli(allocator, &swap_process, swap_prompt);
    defer swapped.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 3), swapped.exit_code);
    try std.testing.expectEqual(@as(usize, 0), swapped.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, swapped.stderr, "host changed after confirmation") != null);
    var replacement_still_live = try runProductCli(
        allocator,
        product_z,
        base,
        &.{ "runtime", "get", replacement_runtime_id, "--json" },
    );
    defer replacement_still_live.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), replacement_still_live.exit_code);

    replacement_gui.deinit();
    replacement_gui_active = false;
    _ = c.kill(replacement_child, posix.SIG.TERM);
    var replacement_status: c_int = 0;
    try std.testing.expectEqual(
        replacement_child,
        c.waitpid(replacement_child, &replacement_status, 0),
    );
    removeProductHostFiles(session_dir, replacement_socket, replacement_host_id);
    replacement_active = false;
}
