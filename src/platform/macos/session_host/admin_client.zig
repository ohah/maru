//! Read-only public CLI의 existing-current-host connector.
//! Secure manifest registry를 읽기만 하며 host spawn, lock acquisition, manifest publication을 하지 않는다.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const client_mod = @import("client.zig");
const discovery = @import("discovery.zig");
const host_manifest = @import("host_manifest.zig");
const protocol = @import("protocol.zig");
const recovery_discovery = @import("recovery_discovery.zig");
const screen_stream = @import("screen_stream.zig");
const short_endpoint = @import("short_endpoint.zig");
extern "c" fn usleep(usec: c_uint) c_int;

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

fn readTestPipe(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const read_len = c.read(fd, &buf, buf.len);
        if (read_len < 0) {
            if (posix.errno(read_len) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        if (read_len == 0) break;
        try output.appendSlice(allocator, buf[0..@intCast(read_len)]);
        if (output.items.len > 64 * 1024) return error.TestUnexpectedResult;
    }
    return output.toOwnedSlice(allocator);
}

fn runProductCli(
    allocator: std.mem.Allocator,
    product_exe: [:0]const u8,
    xdg_cache_home: [:0]const u8,
    args: []const [:0]const u8,
) !ProductResult {
    var stdout_fds: [2]c_int = undefined;
    var stderr_fds: [2]c_int = undefined;
    if (c.pipe(&stdout_fds) != 0) return error.TestUnexpectedResult;
    if (c.pipe(&stderr_fds) != 0) {
        _ = c.close(stdout_fds[0]);
        _ = c.close(stdout_fds[1]);
        return error.TestUnexpectedResult;
    }
    const env_arg = try std.fmt.allocPrintSentinel(
        allocator,
        "XDG_CACHE_HOME={s}",
        .{xdg_cache_home},
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
    const stdout = try readTestPipe(allocator, stdout_fds[0]);
    errdefer allocator.free(stdout);
    const stderr = try readTestPipe(allocator, stderr_fds[0]);
    errdefer allocator.free(stderr);
    _ = c.close(stdout_fds[0]);
    _ = c.close(stderr_fds[0]);
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return error.TestUnexpectedResult;
    const unsigned: u32 = @bitCast(status);
    return .{
        .exit_code = if (c.W.IFEXITED(unsigned)) @intCast(c.W.EXITSTATUS(unsigned)) else -1,
        .stdout = stdout,
        .stderr = stderr,
    };
}

fn spawnProductHost(
    product_exe: [*:0]const u8,
    xdg: [:0]const u8,
    session_dir: [:0]const u8,
    socket_path: [:0]const u8,
    host_text: [:0]const u8,
) !c.pid_t {
    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        var env_buf: [256]u8 = undefined;
        const env_arg = std.fmt.bufPrintZ(&env_buf, "XDG_CACHE_HOME={s}", .{xdg}) catch c._exit(127);
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
    const host_id = (pid_bits << 64) | 0xC11A2;
    var xdg_buf: [192]u8 = undefined;
    const xdg = try std.fmt.bufPrintZ(&xdg_buf, "/tmp/maru-admin-cli-{d}", .{c.getpid()});
    _ = c.mkdir(xdg.ptr, 0o700);
    var base_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&base_buf, "{s}/maru", .{xdg});
    _ = c.mkdir(base.ptr, 0o700);
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
        xdg,
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
        xdg,
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
        xdg,
        &.{ "runtime", "get", "aabb" },
    );
    defer usage.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 2), usage.exit_code);
    try std.testing.expectEqual(@as(usize, 0), usage.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, usage.stderr, "usage:") != null);

    const child = try spawnProductHost(product_raw, xdg, session_dir, socket_path, host_text);
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = 0;
        _ = c.waitpid(child, &status, 0);
        removeProductHostFiles(session_dir, socket_path, host_id);
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, session_dir)) |path|
            _ = c.rmdir(path.ptr)
        else |_| {}
        _ = c.rmdir(session_dir.ptr);
        _ = c.rmdir(base.ptr);
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
        xdg,
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
        xdg,
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
        xdg,
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
        xdg,
        &.{ "host", "status", "--json" },
    );
    defer busy_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 6), busy_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), busy_result.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, busy_result.stderr, "\n"));
    held_admin.deinit();

    var gui = try client_mod.Client.connect(allocator, socket_path, "gui");
    errdefer gui.deinit();
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
        xdg,
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
        xdg,
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
        xdg,
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
        xdg,
        &.{ "runtime", "get", "ffffffffffffffffffffffffffffffff", "--json" },
    );
    defer missing_result.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 7), missing_result.exit_code);
    try std.testing.expectEqual(@as(usize, 0), missing_result.stdout.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, missing_result.stderr, "\n"));

    var with_gui = try runProductCli(
        allocator,
        product_z,
        xdg,
        &.{ "host", "status", "--json" },
    );
    defer with_gui.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), with_gui.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, with_gui.stdout, "\"runtime_count\":1,\"client_count\":2") != null);
    gui.deinit();

    var after_gui = try runProductCli(
        allocator,
        product_z,
        xdg,
        &.{ "host", "status", "--json" },
    );
    defer after_gui.deinit(allocator);
    try std.testing.expectEqual(@as(c_int, 0), after_gui.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, after_gui.stdout, "\"runtime_count\":1,\"client_count\":1") != null);
    try std.testing.expectEqualDeep(manifest_before, try snapshotFile(manifest_path));
    try std.testing.expectEqualDeep(owner_before, try snapshotFile(owner_path));
    try std.testing.expect(c.fstatat(
        posix.AT.FDCWD,
        launch_path.ptr,
        &launch_stat,
        posix.AT.SYMLINK_NOFOLLOW,
    ) != 0);
}
