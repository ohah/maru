//! host_connect — client의 **connect-or-launch 오케스트레이션**(§10 발견 실행층) — P3-e3-4.
//!
//! `discovery.zig`(순수 state machine)의 결정을 실 syscall(connect/flock/spawnDetached)로 **수행**한다: host가 있으면
//! 붙고, 없으면 detached helper를 **하나만** 띄워 붙는다(여러 GUI가 동시에 시작해도 중복 spawn 없이 — start lock winner만
//! spawn). AppSession이 keep-alive일 때 이걸 불러 host connection을 얻는다(e3-4b). 실패하면 null → caller가 in-process로
//! 폴백한다(host 문제가 GUI를 막지 않는다). macOS 전용(실 fork/exec/flock; 순수 결정은 discovery.zig가 이미 테스트).

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const discovery = @import("discovery.zig");
const launcher = @import("launcher.zig");
const client_mod = @import("client.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const registry_mod = @import("registry.zig");
const socket_server = @import("socket_server.zig");
const host_manifest = @import("host_manifest.zig");
const short_endpoint = @import("short_endpoint.zig");
const screen_stream = @import("screen_stream.zig");

// flock(2)은 std.c 미노출(macOS 전용). start lock 직렬화용. LOCK_EX=2·LOCK_NB=4(sys/file.h).
extern "c" fn flock(fd: c_int, operation: c_int) c_int;
const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
extern "c" fn usleep(usec: c_uint) c_int;
extern "c" fn arc4random_buf(buf: [*]u8, nbytes: usize) void;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Options = struct {
    /// spawn 뒤(또는 lock loser로서) host가 뜰 때까지 재connect 시도 횟수 × 간격. 기본 150×20ms=3s(cold launch 여유).
    connect_attempts: usize = 150,
    connect_delay_ms: u32 = 20,
};

pub const FailureReason = enum {
    invalid_endpoint,
    endpoint_denied,
    incompatible_version,
    handshake_failed,
    protocol_error,
    launch_failed,
    startup_timeout,
    invalid_manifest,
    stale_manifest,
    out_of_memory,
};

pub const Outcome = union(enum) {
    connected: client_mod.Client,
    failed: FailureReason,
};

/// host에 연결하거나(있으면) detached helper를 띄워 연결한다(§10 connect-first→start-lock→spawn). 반환 `Client`는
/// **caller 소유**(deinit 책임). `null`이면 host를 못 얻었다(권한 거부·spawn 실패·denied 등) — caller는 in-process로
/// 폴백한다. `exe_path`=현재 maru 실행 파일(helper로 exec), `base_cache_dir`=user cache dir(그 아래 `session-host/`).
pub fn connectOrLaunch(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    opts: Options,
) ?client_mod.Client {
    return switch (connectOrLaunchDetailed(allocator, exe_path, base_cache_dir, opts)) {
        .connected => |client| client,
        .failed => null,
    };
}

pub fn connectOrLaunchDetailed(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    opts: Options,
) Outcome {
    if (builtin.os.tag != .macos) return .{ .failed = .invalid_endpoint };

    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch return .{ .failed = .invalid_endpoint };

    // Manifest-capable host는 host별 short endpoint를 쓰므로 fixed major socket보다 registry를 먼저 본다.
    if (findCurrentManifestHost(allocator, exe_path, base_cache_dir, dir)) |outcome| return outcome;

    var sock_buf: [640]u8 = undefined;
    const socket = discovery.socketPathIn(&sock_buf, dir) catch return .{ .failed = .invalid_endpoint };
    var legacy_sock_buf: [640]u8 = undefined;
    const legacy_socket = discovery.legacySocketPathIn(&legacy_sock_buf, dir) catch return .{ .failed = .invalid_endpoint };

    // 1. connect-first(§10): 있으면 바로 쓴다.
    switch (tryConnect(allocator, socket)) {
        .connected => |client| return .{ .connected = client },
        .absent => {},
        .transient => return connectWithBackoffDetailed(allocator, socket, opts),
        .failed => |reason| return .{ .failed = reason },
    }

    // versioned endpoint 전환 이전의 current-major host는 그대로 재사용한다. legacy endpoint의 다른 major는
    // current header handshake를 닫으므로 새 versioned host를 side-by-side로 시작하고, saved runtime restore가
    // 별도 N-1 adapter로 legacy endpoint를 찾는다.
    switch (tryConnect(allocator, legacy_socket)) {
        .connected => |client| return .{ .connected = client },
        .absent => {},
        .transient => return connectWithBackoffDetailed(allocator, legacy_socket, opts),
        .failed => |reason| switch (reason) {
            .incompatible_version, .handshake_failed, .protocol_error => {},
            else => return .{ .failed = reason },
        },
    }

    // 2. need_start_lock: lock 파일을 열고 nonblocking flock으로 "내가 시작 책임인가"를 가른다. lock은 fd close로 해제되며,
    // spawn+재connect가 끝날 때까지(defer) 잡고 있어 동시 시작자들이 하나의 host로 수렴하게 한다(daemon은 socket bind가
    // liveness라 lock을 안 쓴다 — 순수 시작 직렬화용).
    ensureDir(dir);
    const lock_fd = openLock(dir) orelse return .{ .failed = .endpoint_denied };
    defer _ = c.close(lock_fd);
    const lock_probe: discovery.LockProbe = if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) .acquired else .contended;

    // 3. lock 취득/경합 뒤 다시 connect(§10 "lock 직전 race"): 그 사이 다른 프로세스가 bind했을 수 있다.
    switch (tryConnect(allocator, socket)) {
        .connected => |client| return .{ .connected = client },
        .transient => return connectWithBackoffDetailed(allocator, socket, opts),
        .failed => |reason| return .{ .failed = reason },
        .absent => {},
    }
    if (lock_probe == .contended) {
        if (connectManifestRegistryWithBackoff(allocator, exe_path, base_cache_dir, dir, opts)) |outcome|
            return outcome;
        // 이전 winner가 publish 전에 실패했으면 loser가 영구 fallback하지 않고 lock을 한 번 재획득해 launch owner가 된다.
        if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) return .{ .failed = .startup_timeout };
    }

    // Lock 취득 뒤 registry도 다시 읽는다. 다른 process가 manifest를 publish한 직후 fixed endpoint가 비어 있는
    // host-specific 모델에서도 중복 spawn을 막는다.
    if (findCurrentManifestHost(allocator, exe_path, base_cache_dir, dir)) |outcome| return outcome;

    short_endpoint.prepareCurrentUserNamespace() catch return .{ .failed = .endpoint_denied };
    var host_id: u128 = 0;
    while (host_id == 0) arc4random_buf(std.mem.asBytes(&host_id).ptr, @sizeOf(u128));
    var short_socket_buf: [128]u8 = undefined;
    const short_socket = short_endpoint.currentSocketPathIn(&short_socket_buf, host_id) catch
        return .{ .failed = .invalid_endpoint };
    launcher.spawnSessionHostDetached(allocator, exe_path, dir, short_socket, host_id) catch
        return .{ .failed = .launch_failed };
    return connectNewHostWithBackoff(allocator, base_cache_dir, host_id, opts);
}

fn findCurrentManifestHost(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    session_dir: [:0]const u8,
) ?Outcome {
    const build_id = host_manifest.buildIdForExecutable(allocator, exe_path) catch return null;
    defer allocator.free(build_id);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = host_manifest.hostsRootPathIn(&hosts_buf, session_dir) catch return .{ .failed = .invalid_endpoint };
    const directory = c.opendir(hosts_root.ptr) orelse return null;
    defer _ = c.closedir(directory);
    while (c.readdir(directory)) |entry| {
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (name.len != 32) continue;
        const host_id = std.fmt.parseInt(u128, name, 16) catch continue;
        if (host_id == 0) continue;
        var manifest = host_manifest.load(allocator, session_dir, host_id) catch continue;
        defer manifest.deinit();
        if (manifest.protocol_major != protocol.version_major or
            manifest.screen_codec_version != screen_stream.codec_version or
            manifest.lifecycle != .ready or
            !std.mem.eql(u8, manifest.build_id, build_id) or
            !ownerLeaseIsLive(session_dir, host_id))
            continue;
        switch (connectExistingHost(allocator, base_cache_dir, host_id)) {
            .connected => |client| return .{ .connected = client },
            .failed => |reason| if (reason == .out_of_memory) return .{ .failed = reason },
        }
    }
    return null;
}

fn ownerLeaseIsLive(session_dir: [:0]const u8, host_id: u128) bool {
    var path_buf: [832]u8 = undefined;
    const path = host_manifest.ownerLockPathIn(&path_buf, session_dir, host_id) catch return false;
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDWR, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const rc = flock(fd, LOCK_EX | LOCK_NB);
    if (rc == 0) return false;
    return posix.errno(rc) == .AGAIN;
}

fn connectNewHostWithBackoff(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
    opts: Options,
) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (connectExistingHost(allocator, base_cache_dir, host_id)) {
            .connected => |client| return .{ .connected = client },
            .failed => |reason| switch (reason) {
                .startup_timeout, .invalid_manifest => {},
                else => return .{ .failed = reason },
            },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

fn connectManifestRegistryWithBackoff(
    allocator: std.mem.Allocator,
    exe_path: [:0]const u8,
    base_cache_dir: []const u8,
    session_dir: [:0]const u8,
    opts: Options,
) ?Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        if (findCurrentManifestHost(allocator, exe_path, base_cache_dir, session_dir)) |outcome|
            return outcome;
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return null;
}

/// 이미 존재하는 특정 major host만 찾는다. 조회/restore 경로라 spawn하지 않으며 versioned endpoint를 먼저,
/// 전환 이전 legacy endpoint를 다음으로 probe한다.
pub fn connectExistingMajor(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    major: u16,
) Outcome {
    if (builtin.os.tag != .macos) return .{ .failed = .invalid_endpoint };
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch return .{ .failed = .invalid_endpoint };
    var versioned_buf: [640]u8 = undefined;
    const versioned = discovery.socketPathForMajorIn(&versioned_buf, dir, major) catch
        return .{ .failed = .invalid_endpoint };
    switch (tryConnectMajor(allocator, versioned, major)) {
        .connected => |client| return .{ .connected = client },
        .absent => {},
        .transient => return connectMajorWithBackoffDetailed(allocator, versioned, major, .{
            .connect_attempts = 10,
            .connect_delay_ms = 20,
        }),
        .failed => |reason| return .{ .failed = reason },
    }
    var legacy_buf: [640]u8 = undefined;
    const legacy = discovery.legacySocketPathIn(&legacy_buf, dir) catch return .{ .failed = .invalid_endpoint };
    return switch (tryConnectMajor(allocator, legacy, major)) {
        .connected => |client| .{ .connected = client },
        .absent => .{ .failed = .startup_timeout },
        .transient => connectMajorWithBackoffDetailed(allocator, legacy, major, .{
            .connect_attempts = 10,
            .connect_delay_ms = 20,
        }),
        .failed => |reason| .{ .failed = reason },
    };
}

/// Workspace의 exact `host_id`를 registry manifest로 resolve한다. Manifest가 있으면 그 endpoint/major만 사용하고
/// hello identity·screen codec이 하나라도 다르면 다른 major socket을 추측하지 않는다. Manifest 도입 전 host에 한해
/// current/N-1 legacy endpoint를 제한적으로 probe하고 hello host_id가 정확히 같은 연결만 반환한다.
pub fn connectExistingHost(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
) Outcome {
    if (builtin.os.tag != .macos or host_id == 0) return .{ .failed = .invalid_endpoint };
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .failed = .invalid_endpoint };
    const manifest = host_manifest.load(allocator, dir, host_id) catch |err| switch (err) {
        error.ManifestNotFound => return connectLegacyExact(allocator, base_cache_dir, host_id),
        error.OutOfMemory => return .{ .failed = .out_of_memory },
        else => return .{ .failed = .invalid_manifest },
    };
    var exact = manifest;
    defer exact.deinit();
    if (exact.lifecycle == .restoring) return .{ .failed = .startup_timeout };
    const endpoint = allocator.dupeZ(u8, exact.endpoint) catch return .{ .failed = .out_of_memory };
    defer allocator.free(endpoint);
    return connectExactWithBackoff(
        allocator,
        endpoint,
        exact.protocol_major,
        exact.descriptor(),
        .{ .connect_attempts = 10, .connect_delay_ms = 20 },
    );
}

fn connectLegacyExact(allocator: std.mem.Allocator, base_cache_dir: []const u8, host_id: u128) Outcome {
    var dir_buf: [512]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base_cache_dir) catch
        return .{ .failed = .invalid_endpoint };
    var major = protocol.version_major;
    const minimum = if (protocol.version_major > 1) protocol.version_major - 1 else protocol.version_major;
    while (true) {
        var versioned_buf: [640]u8 = undefined;
        const versioned = discovery.socketPathForMajorIn(&versioned_buf, dir, major) catch
            return .{ .failed = .invalid_endpoint };
        if (probeLegacyExactEndpoint(allocator, versioned, major, host_id)) |outcome| switch (outcome) {
            .connected => |client| return .{ .connected = client },
            .failed => |reason| if (reason != .startup_timeout) return .{ .failed = reason },
        };

        // 같은 major의 versioned current host가 다른 host_id여도 전환 전 control.sock을 별도로 probe한다. 한 endpoint의
        // 성공이 다른 endpoint를 shadow하지 않게 해야 saved legacy handle을 정확히 복원할 수 있다.
        var legacy_buf: [640]u8 = undefined;
        const legacy = discovery.legacySocketPathIn(&legacy_buf, dir) catch
            return .{ .failed = .invalid_endpoint };
        if (probeLegacyExactEndpoint(allocator, legacy, major, host_id)) |outcome| switch (outcome) {
            .connected => |client| return .{ .connected = client },
            .failed => |reason| if (reason != .startup_timeout) return .{ .failed = reason },
        };
        if (major == minimum) break;
        major -= 1;
    }
    return .{ .failed = .startup_timeout };
}

fn probeLegacyExactEndpoint(
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    major: u16,
    host_id: u128,
) ?Outcome {
    return switch (tryConnectMajor(allocator, endpoint, major)) {
        .connected => |client| blk: {
            // Manifest-capable peer가 entry를 잃었다면 legacy 추측으로 우회하지 않는다. 이 경우 registry corruption/stale
            // publish를 숨기지 않고 exact manifest 오류로 닫는다.
            if (client.host_manifest_v1) {
                var rejected = client;
                rejected.deinit();
                break :blk .{ .failed = .invalid_manifest };
            }
            if (client.host_id == host_id) break :blk .{ .connected = client };
            var mismatch = client;
            mismatch.deinit();
            break :blk .{ .failed = .startup_timeout };
        },
        .absent, .transient => null,
        .failed => |reason| switch (reason) {
            .incompatible_version, .handshake_failed, .protocol_error => null,
            else => .{ .failed = reason },
        },
    };
}

fn validateExactClient(client: client_mod.Client, expected: host_manifest.Descriptor) Outcome {
    if (client.host_manifest_v1 and client.host_id == expected.host_id and
        client.screen_codec_version == expected.screen_codec_version and
        client.wire_major == expected.protocol_major and
        client.build_id != null and std.mem.eql(u8, client.build_id.?, expected.build_id) and
        client.upgrade_epoch == expected.upgrade_epoch and
        std.mem.eql(u8, client.lifecycle, @tagName(expected.lifecycle)))
        return .{ .connected = client };
    var stale = client;
    stale.deinit();
    return .{ .failed = .stale_manifest };
}

fn connectExactWithBackoff(
    allocator: std.mem.Allocator,
    endpoint: [:0]const u8,
    major: u16,
    expected: host_manifest.Descriptor,
    opts: Options,
) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnectMajor(allocator, endpoint, major)) {
            .connected => |client| return validateExactClient(client, expected),
            .absent, .transient => {},
            .failed => |reason| return .{ .failed = reason },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

const TryConnectResult = union(enum) {
    connected: client_mod.Client,
    absent,
    transient,
    failed: FailureReason,
};

fn connectFailure(err: client_mod.ClientError) TryConnectResult {
    return switch (err) {
        error.EndpointAbsent => .absent,
        error.EndpointTransient => .transient,
        error.EndpointDenied => .{ .failed = .endpoint_denied },
        error.IncompatibleVersion => .{ .failed = .incompatible_version },
        error.HandshakeFailed, error.ConnectionClosed, error.WriteFailed => .{ .failed = .handshake_failed },
        error.ProtocolError, error.EventQueueFull => .{ .failed = .protocol_error },
        error.OutOfMemory => .{ .failed = .out_of_memory },
    };
}

test "host_connect preserves endpoint and handshake failure classes" {
    try testing.expect(connectFailure(error.EndpointAbsent) == .absent);
    try testing.expect(connectFailure(error.EndpointTransient) == .transient);
    try testing.expectEqual(FailureReason.endpoint_denied, connectFailure(error.EndpointDenied).failed);
    try testing.expectEqual(FailureReason.incompatible_version, connectFailure(error.IncompatibleVersion).failed);
    try testing.expectEqual(FailureReason.handshake_failed, connectFailure(error.ConnectionClosed).failed);
    try testing.expectEqual(FailureReason.protocol_error, connectFailure(error.ProtocolError).failed);
    try testing.expectEqual(FailureReason.out_of_memory, connectFailure(error.OutOfMemory).failed);
}

fn readExact(fd: c.fd_t, bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc > 0) {
            offset += @intCast(rc);
            continue;
        }
        if (rc < 0 and posix.errno(rc) == .INTR) continue;
        return false;
    }
    return true;
}

const FrozenV1Peer = struct {
    fn serve(server: *socket_server.SocketServer, ok: *bool) void {
        const fd = server.acceptOne() orelse return;
        defer _ = c.close(fd);
        var header_bytes: [protocol.header_size]u8 = undefined;
        if (!readExact(fd, &header_bytes)) return;
        const header = protocol.Header.decode(&header_bytes) catch return;
        if (header.major != 1 or header.kind != .hello) return;
        const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return;
        defer std.heap.page_allocator.free(payload);
        if (!readExact(fd, payload)) return;
        if (std.mem.indexOf(u8, payload, "\"protocol_min\":1") == null or
            std.mem.indexOf(u8, payload, "\"protocol_max\":1") == null) return;
        const response = framing.encodeFrame(
            std.heap.page_allocator,
            .{ .kind = .hello_ack, .major = 1 },
            "{\"version\":1,\"host_id\":\"000000000000000000000000000000aa\",\"capabilities\":[\"screen_stream_v1_current_body\"]}",
        ) catch return;
        defer std.heap.page_allocator.free(response);
        socket_server.writeAll(fd, response) catch return;
        ok.* = true;
    }
};

test "host_connect finds an existing frozen N-1 major without spawning and preserves adapter major" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-v1-{d}", .{c.getpid()}) catch
        return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700);
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var socket_buf: [320]u8 = undefined;
    const socket = discovery.socketPathForMajorIn(&socket_buf, dir, 1) catch return error.SkipZigTest;
    var registry = registry_mod.TerminalRuntimeRegistry.init(allocator);
    defer registry.deinit();
    var server = try socket_server.SocketServer.bind(allocator, dir, socket, 0xAA, &registry);
    defer {
        server.deinit();
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }
    var served = false;
    var thread = try std.Thread.spawn(.{}, FrozenV1Peer.serve, .{ &server, &served });
    const outcome = connectExistingMajor(allocator, base, 1);
    var client = switch (outcome) {
        .connected => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    thread.join();
    defer client.deinit();
    try testing.expect(served);
    try testing.expectEqual(@as(u16, 1), client.wire_major);
    try testing.expectEqual(@as(u128, 0xAA), client.host_id);
}

/// 한 번 connect를 시도하되 endpoint 부재/권한/일시 오류와 wire 실패를 잃지 않는다.
fn tryConnect(allocator: std.mem.Allocator, socket: [:0]const u8) TryConnectResult {
    if (client_mod.Client.connect(allocator, socket, "gui")) |client| {
        return .{ .connected = client };
    } else |err| {
        return connectFailure(err);
    }
}

fn tryConnectMajor(allocator: std.mem.Allocator, socket: [:0]const u8, major: u16) TryConnectResult {
    if (client_mod.Client.connectMajor(allocator, socket, "gui", major)) |client| {
        return .{ .connected = client };
    } else |err| {
        return connectFailure(err);
    }
}

fn connectWithBackoffDetailed(allocator: std.mem.Allocator, socket: [:0]const u8, opts: Options) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnect(allocator, socket)) {
            .connected => |client| return .{ .connected = client },
            .absent, .transient => {},
            .failed => |reason| return .{ .failed = reason },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

fn connectMajorWithBackoffDetailed(
    allocator: std.mem.Allocator,
    socket: [:0]const u8,
    major: u16,
    opts: Options,
) Outcome {
    var attempts: usize = 0;
    while (attempts < opts.connect_attempts) : (attempts += 1) {
        switch (tryConnectMajor(allocator, socket, major)) {
            .connected => |client| return .{ .connected = client },
            .absent, .transient => {},
            .failed => |reason| return .{ .failed = reason },
        }
        _ = usleep(opts.connect_delay_ms * 1000);
    }
    return .{ .failed = .startup_timeout };
}

/// session-host 디렉터리를 0700으로 만든다(best-effort — EEXIST 무해). lock 파일 생성에 필요하다. 소유/perm의 진짜
/// 검증은 host `SocketServer.bind`가 fstatat(SYMLINK_NOFOLLOW)로 한다(§11) — 여기선 lock을 놓을 자리만 확보한다.
fn ensureDir(dir: [:0]const u8) void {
    _ = c.mkdir(dir.ptr, 0o700);
}

fn openLock(dir: [:0]const u8) ?c.fd_t {
    var lock_buf: [640]u8 = undefined;
    const lock = discovery.lockPathIn(&lock_buf, dir) catch return null;
    const fd = c.open(lock.ptr, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return null;
    return fd;
}

// ─────────────────────────────────────────────────────────────────────────────
// process smoke (실 macOS: fork host에 connect-first로 붙고, host 없을 땐 폴백)
//
// 이 테스트가 증명하는 것(그리고 왜 e3에서 중요한가): keep-alive GUI가 시작할 때 "있으면 붙고 없으면 하나 띄운다"는
// 발견 실행층이 실제 socket/flock/connect로 도는지 고정한다. use_connection(이미 뜬 host에 붙음), 제품 `maru`
// 바이너리의 spawn_host argv/hidden-command 진입, 폴백(host도 없고 spawn도 실패 → null로 in-process 유지)을 검증한다.
// 실 syscall이라 macOS opt-in.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const daemon = @import("daemon.zig");

test "host_connect: connect-first attaches to an already-running host (no spawn)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;
    const io = testing.io;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-hc-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700); // 제품에선 base=user cache dir(이미 존재). host bind는 <base>/session-host만 mkdir하므로 base를 먼저 만든다.
    // discovery 경로와 동일하게 host별 short endpoint + cache manifest를 띄운다.
    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    _ = c.mkdir(dir.ptr, 0o700);
    const host_id: u128 = 0xAABBCCDD;
    try short_endpoint.prepareCurrentUserNamespace();
    var sock_buf: [128]u8 = undefined;
    const socket = try short_endpoint.currentSocketPathIn(&sock_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        _ = c.setsid();
        _ = unsetenv("MARU_SESSION_HOST_TEST_ONESHOT");
        daemon.runSessionHostWithIdentity(std.heap.page_allocator, io, dir, socket, host_id) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        _ = c.unlink(socket.ptr);
        var manifest_buf: [832]u8 = undefined;
        if (host_manifest.manifestPathIn(&manifest_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var owner_buf: [832]u8 = undefined;
        if (host_manifest.ownerLockPathIn(&owner_buf, dir, host_id)) |path| _ = c.unlink(path.ptr) else |_| {}
        var host_dir_buf: [768]u8 = undefined;
        if (host_manifest.hostDirPathIn(&host_dir_buf, dir, host_id)) |path| _ = c.rmdir(path.ptr) else |_| {}
        var hosts_buf: [640]u8 = undefined;
        if (host_manifest.hostsRootPathIn(&hosts_buf, dir)) |path| _ = c.rmdir(path.ptr) else |_| {}
        _ = c.rmdir(dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    // host가 bind할 때까지 잠깐 기다렸다가 connect-first로 붙는다(spawn 없이). exe_path는 이 경로에선 안 쓰이므로 더미.
    // (호스트가 아직 안 떴으면 첫 connect가 absent→start-lock→우리가 spawn을 시도하는데, 더미 exe라 폴백될 수 있어
    //  host가 확실히 뜰 때까지 기다린 뒤 부른다.)
    var up = false;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (client_mod.Client.connect(allocator, socket, "gui")) |cl| {
            var probe = cl;
            probe.deinit();
            up = true;
            break;
        } else |_| _ = usleep(20 * 1000);
    }
    try testing.expect(up);

    const current_exe_raw = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(current_exe_raw);
    const current_exe = try allocator.dupeZ(u8, current_exe_raw);
    defer allocator.free(current_exe);
    {
        var client = connectOrLaunch(allocator, current_exe, base, .{ .connect_attempts = 5, .connect_delay_ms = 10 }) orelse {
            try testing.expect(false);
            return;
        };
        defer client.deinit();
        try testing.expectEqual(host_id, client.host_id);
        try testing.expect(client.host_manifest_v1);
    }

    // Workspace restore는 major endpoint를 추측하지 않고 daemon이 publish한 exact host manifest를 따라간다.
    {
        var exact = switch (connectExistingHost(allocator, base, host_id)) {
            .connected => |value| value,
            .failed => return error.TestUnexpectedResult,
        };
        defer exact.deinit();
        try testing.expectEqual(host_id, exact.host_id);
    }

    // 같은 host_id/endpoint라도 disk generation의 build identity가 peer와 다르면 stale entry로 거부한다.
    var manifest_path_buf: [832]u8 = undefined;
    const manifest_path = try host_manifest.manifestPathIn(&manifest_path_buf, dir, host_id);
    try testing.expect(c.unlink(manifest_path.ptr) == 0);
    var stale_manifest = try host_manifest.publish(allocator, dir, .{
        .host_id = host_id,
        .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .protocol_major = protocol.version_major,
        .screen_codec_version = @import("screen_stream.zig").codec_version,
        .upgrade_epoch = 0,
        .lifecycle = .ready,
        .endpoint = socket,
    });
    defer stale_manifest.deinit();
    const stale = connectExistingHost(allocator, base, host_id);
    try testing.expectEqual(FailureReason.stale_manifest, stale.failed);
}

test "host_connect: falls back to null when no host exists and spawn cannot bind" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = testing.allocator;

    var base_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-hcf-{d}", .{c.getpid()}) catch return error.SkipZigTest;
    _ = c.mkdir(base.ptr, 0o700); // base 존재 → spawn_host 경로를 실제로 탄다(lock 취득→spawn 실패→backoff→null).
    defer {
        // 테스트가 만든 dir/lock 정리(host는 안 떴다).
        var dir_buf: [256]u8 = undefined;
        if (discovery.sessionHostDirPath(&dir_buf, base)) |dir| {
            var lp_buf: [320]u8 = undefined;
            if (discovery.lockPathIn(&lp_buf, dir)) |lp| _ = c.unlink(lp.ptr) else |_| {}
            _ = c.rmdir(dir.ptr);
        } else |_| {}
        _ = c.rmdir(base.ptr);
    }

    // host 없음 + helper exe가 bind 못 함(/nonexistent → exec 실패 _exit 127) → 짧은 backoff 뒤 null(in-process 폴백).
    const result = connectOrLaunch(allocator, "/nonexistent-maru-helper", base, .{ .connect_attempts = 3, .connect_delay_ms = 10 });
    try testing.expect(result == null);
}

test "host_connect: launches the product maru session host and completes host.info" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // `@import("root")`는 Zig test runner module 배치에 따라 이 barrel의
    // declaration을 보지 못해 전용 `test-session-host`에서도 조용히
    // skip됐다. Build step이 주는 exact marker로 전용 실행과 전체 test의
    // 중복 수집을 구분하고, marker가 있는데 product artifact가 빠졌다면
    // wiring 회귀로 실패시킨다.
    const required = std.c.getenv(
        "MARU_SESSION_HOST_REQUIRE_PRODUCT_LAUNCH_SMOKE",
    ) orelse return error.SkipZigTest;
    if (!std.mem.eql(
        u8,
        std.mem.span(required),
        "maru-test-only-v1",
    )) return error.SkipZigTest;
    const allocator = testing.allocator;
    const product_exe_raw = std.c.getenv("MARU_SESSION_HOST_PRODUCT_EXE") orelse {
        try testing.expect(false); // macOS 공식 build wiring이 product artifact 주입을 잃으면 skip이 아니라 실패한다.
        return;
    };
    const product_exe: [:0]const u8 = std.mem.span(product_exe_raw);

    // PID만 쓰면 강제 종료 뒤 PID 재사용 시 stale host에 connect-first로 붙어 새 product exec를 건너뛸 수 있다.
    // CSPRNG nonce + 배타적 mkdir로 매 실행의 launch 경로가 비어 있음을 보장한다.
    var nonce: u64 = undefined;
    arc4random_buf(std.mem.asBytes(&nonce).ptr, @sizeOf(u64));
    var base_buf: [160]u8 = undefined;
    const base = std.fmt.bufPrintZ(&base_buf, "/tmp/maru-sh-product-{d}-{x}", .{ c.getpid(), nonce }) catch return error.SkipZigTest;
    try testing.expectEqual(@as(c_int, 0), c.mkdir(base.ptr, 0o700));

    var dir_buf: [256]u8 = undefined;
    const dir = discovery.sessionHostDirPath(&dir_buf, base) catch return error.SkipZigTest;
    var launched_host_id: u128 = 0;
    var launched_socket_buf: [128]u8 = undefined;

    {
        var client = connectOrLaunch(allocator, product_exe, base, .{}) orelse {
            try testing.expect(false);
            return;
        };
        defer client.deinit();
        launched_host_id = client.host_id;
        try testing.expect(client.host_manifest_v1);
        _ = try short_endpoint.currentSocketPathIn(&launched_socket_buf, launched_host_id);
        const response = try client.call("host.info", null);
        defer allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"runtime_count\":0") != null);
    }

    var owner_buf: [832]u8 = undefined;
    const owner_path = try host_manifest.ownerLockPathIn(&owner_buf, dir, launched_host_id);
    var manifest_buf: [832]u8 = undefined;
    const manifest_path = try host_manifest.manifestPathIn(&manifest_buf, dir, launched_host_id);
    var host_dir_buf: [768]u8 = undefined;
    const host_dir = try host_manifest.hostDirPathIn(&host_dir_buf, dir, launched_host_id);
    var hosts_buf: [640]u8 = undefined;
    const hosts_root = try host_manifest.hostsRootPathIn(&hosts_buf, dir);

    // oneshot host의 정상 종료가 endpoint뿐 아니라 manifest→owner lock→빈 registry directory 순으로 전부 회수하는지
    // 확인한다. 테스트가 직접 지우면 제품의 누적 회귀를 숨기므로 부재만 관찰한다.
    var stopped = false;
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (c.access(@ptrCast(&launched_socket_buf), 0) != 0 and
            c.access(manifest_path.ptr, 0) != 0 and
            c.access(owner_path.ptr, 0) != 0 and
            c.access(host_dir.ptr, 0) != 0 and
            c.access(hosts_root.ptr, 0) != 0)
        {
            stopped = true;
            break;
        }
        _ = usleep(20 * 1000);
    }
    try testing.expect(stopped);

    var lock_buf: [320]u8 = undefined;
    if (discovery.lockPathIn(&lock_buf, dir)) |lock| _ = c.unlink(lock.ptr) else |_| {}
    _ = c.rmdir(dir.ptr);
    _ = c.rmdir(base.ptr);
}
