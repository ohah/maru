//! Public attach 제품 adapter. Secure registry/path/socket 관찰과 isolated runtime.get wire,
//! pinned long connection을 소유하며 순수 all-or-none 결정은 attach_resolver에 위임한다.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const attach_cli = @import("maru").cli.attach;
const compatibility = @import("compatibility.zig");
const discovery = @import("discovery.zig");
const host_connect = @import("host_connect.zig");
const host_manifest = @import("host_manifest.zig");
const recovery_discovery = @import("recovery_discovery.zig");
const remote_attachment = @import("remote_attachment.zig");
const runtime_event_types = @import("runtime_event_types.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const resolver = @import("attach_resolver.zig");
const socket_server = @import("socket_server.zig");
const attach_phase_deadline = @import("attach_phase_deadline.zig");
extern "c" fn usleep(usec: c_uint) c_int;

fn runTestSocketProxy(listener: c.fd_t, upstream_path: [:0]const u8) noreturn {
    while (true) {
        const downstream = c.accept(listener, null, null);
        if (downstream < 0) std.c._exit(91);
        const upstream = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        if (upstream < 0) std.c._exit(92);
        var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..upstream_path.len], upstream_path);
        if (c.connect(upstream, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
            std.c._exit(93);
        socket_server.setNoSigPipe(downstream);
        socket_server.setNoSigPipe(upstream);
        var fds = [_]posix.pollfd{
            .{ .fd = downstream, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = upstream, .events = c.POLL.IN, .revents = 0 },
        };
        var buffer: [4096]u8 = undefined;
        while (true) {
            const ready = c.poll(&fds, fds.len, -1);
            if (ready <= 0) continue;
            var closed = false;
            for (fds, 0..) |poll_fd, index| {
                if (poll_fd.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) == 0) continue;
                const source = poll_fd.fd;
                const target = fds[1 - index].fd;
                const count = c.read(source, &buffer, buffer.len);
                if (count <= 0) {
                    closed = true;
                    break;
                }
                socket_server.writeAll(target, buffer[0..@intCast(count)]) catch {
                    closed = true;
                    break;
                };
            }
            if (closed) break;
        }
        _ = c.close(downstream);
        _ = c.close(upstream);
    }
}

pub const SocketIdentity = struct {
    dev: posix.dev_t,
    ino: posix.ino_t,

    pub fn eql(a: SocketIdentity, b: SocketIdentity) bool {
        return a.dev == b.dev and a.ino == b.ino;
    }
};

/// Discovery-owned Manifest slices cannot outlive the enumeration. The public attach path carries
/// this owned value across cleanup and pins the exact socket inode observed after membership
/// resolution; a fresh registry load and inode observation must match before the long connection.
pub const ResolvedHostDescriptor = struct {
    allocator: std.mem.Allocator,
    runtime_id: u128,
    host_id: u128,
    build_id: []u8,
    protocol_major: u16,
    screen_codec_version: u16,
    upgrade_epoch: u64,
    lifecycle: host_manifest.Lifecycle,
    endpoint: [:0]u8,
    socket_identity: SocketIdentity,

    pub fn init(
        allocator: std.mem.Allocator,
        runtime_id: u128,
        source: host_manifest.Descriptor,
        identity: SocketIdentity,
    ) error{OutOfMemory}!ResolvedHostDescriptor {
        const build_id = allocator.dupe(u8, source.build_id) catch
            return error.OutOfMemory;
        errdefer allocator.free(build_id);
        const endpoint = allocator.dupeZ(u8, source.endpoint) catch
            return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .runtime_id = runtime_id,
            .host_id = source.host_id,
            .build_id = build_id,
            .protocol_major = source.protocol_major,
            .screen_codec_version = source.screen_codec_version,
            .upgrade_epoch = source.upgrade_epoch,
            .lifecycle = source.lifecycle,
            .endpoint = endpoint,
            .socket_identity = identity,
        };
    }

    pub fn deinit(self: *ResolvedHostDescriptor) void {
        self.allocator.free(self.build_id);
        self.allocator.free(self.endpoint);
        self.* = undefined;
    }

    pub fn descriptor(self: *const ResolvedHostDescriptor) host_manifest.Descriptor {
        return .{
            .host_id = self.host_id,
            .build_id = self.build_id,
            .protocol_major = self.protocol_major,
            .screen_codec_version = self.screen_codec_version,
            .upgrade_epoch = self.upgrade_epoch,
            .lifecycle = self.lifecycle,
            .endpoint = self.endpoint,
        };
    }
};

pub const ProductResult = union(enum) {
    selected: ResolvedHostDescriptor,
    failed: attach_cli.ExitCode,
};

pub const Connected = union(enum) {
    client: @import("client.zig").Client,
    failed: attach_cli.ExitCode,
};

const ProductProbe = struct {
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    phase: attach_phase_deadline.PhaseDeadline,
    expired_latched: bool = false,

    fn call(
        context: *anyopaque,
        descriptor: host_manifest.Descriptor,
        runtime_id: u128,
    ) attach_cli.Probe {
        const self: *ProductProbe = @ptrCast(@alignCast(context));
        if (self.phase.absolute.remainingNs() <= 0) {
            self.expired_latched = true;
            return .host_unavailable;
        }
        const outcome = host_connect.connectDiscoveredHostProfileUntil(
            self.allocator,
            self.base_cache_dir,
            descriptor,
            .cli_probe,
            self.phase,
        );
        var client = switch (outcome) {
            .connected => |value| value,
            .failed => |reason| {
                if (reason == .deadline_exceeded or self.phase.absolute.remainingNs() <= 0)
                    self.expired_latched = true;
                return connectFailure(reason);
            },
        };
        defer client.deinit();
        var runtime_text: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&runtime_text, "{x:0>32}", .{runtime_id}) catch
            return .out_of_memory;
        var params_buf: [64]u8 = undefined;
        const params = std.fmt.bufPrint(
            &params_buf,
            "{{\"runtime_id\":\"{s}\"}}",
            .{&runtime_text},
        ) catch return .out_of_memory;
        const response = client.callUntil(
            "runtime.get",
            params,
            self.phase.absolute,
        ) catch |err| {
            if (self.phase.absolute.remainingNs() <= 0) {
                self.expired_latched = true;
                return .host_unavailable;
            }
            return switch (err) {
                error.DeadlineExceeded => .host_unavailable,
                error.OutOfMemory => .out_of_memory,
                error.Unauthorized => .denied,
                error.EndpointTransient, error.AdminBusy => .busy,
                error.EndpointAbsent, error.ConnectionClosed, error.WriteFailed => .host_unavailable,
                error.IncompatibleVersion,
                error.HandshakeFailed,
                error.ProtocolError,
                error.EventQueueFull,
                error.ExternalMode,
                => .protocol,
                error.EndpointDenied => .denied,
            };
        };
        defer self.allocator.free(response);
        const decoded = decodeMembership(self.allocator, response, runtime_id);
        if (self.phase.absolute.remainingNs() <= 0) {
            self.expired_latched = true;
            return .host_unavailable;
        }
        return decoded;
    }

    fn ops(self: *ProductProbe) resolver.ProbeOps {
        return .{ .context = self, .probe = call };
    }
};

/// Secure registry discovery plus one isolated CLI connection per eligible host. No call in this
/// path can launch, upgrade, attach, adopt, or terminate a runtime.
pub fn resolveProduct(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    runtime_id: u128,
    phase: attach_phase_deadline.PhaseDeadline,
) ProductResult {
    if (builtin.os.tag != .macos or runtime_id == 0 or phase.kind != .resolve and phase.kind != .connect_hello)
        return .{ .failed = .denied };
    if (phase.absolute.remainingNs() <= 0) return .{ .failed = .host_unavailable };
    var session_buf: [512]u8 = undefined;
    const session_dir = discovery.sessionHostDirPath(&session_buf, base_cache_dir) catch
        return .{ .failed = .host_unavailable };
    const registry_absent = registryRootAbsent(session_dir);
    if (phase.absolute.remainingNs() <= 0) return .{ .failed = .host_unavailable };
    var found = recovery_discovery.discover(allocator, session_dir);
    defer found.deinit(allocator);
    if (phase.absolute.remainingNs() <= 0) return .{ .failed = .host_unavailable };
    const entries = switch (found) {
        .unavailable => |reason| return .{ .failed = switch (reason) {
            .out_of_memory => .internal,
            .registry_unavailable => if (registry_absent) .host_unavailable else .denied,
            .too_many_hosts => .denied,
        } },
        .complete => |items| items,
    };
    var probe = ProductProbe{
        .allocator = allocator,
        .base_cache_dir = base_cache_dir,
        .phase = phase,
    };
    const reduced = resolver.resolve(entries, runtime_id, probe.ops());
    if (probe.expired_latched or phase.absolute.remainingNs() <= 0)
        return .{ .failed = .host_unavailable };
    const selected_index = switch (reduced) {
        .failed => |code| return .{ .failed = code },
        .selected_index => |index| index,
    };
    const descriptor = switch (entries[selected_index]) {
        .candidate => |candidate| candidate.manifest.descriptor(),
        .unavailable => return .{ .failed = .denied },
    };
    if (phase.absolute.remainingNs() <= 0) return .{ .failed = .host_unavailable };
    const observed = observeSocket(descriptor.endpoint);
    if (phase.absolute.remainingNs() <= 0) return .{ .failed = .host_unavailable };
    const identity = switch (observed) {
        .identity => |value| value,
        .absent => return .{ .failed = .host_unavailable },
        .denied => return .{ .failed = .denied },
    };
    const owned = ResolvedHostDescriptor.init(allocator, runtime_id, descriptor, identity) catch
        return .{ .failed = .internal };
    if (phase.absolute.remainingNs() <= 0) {
        var expired = owned;
        expired.deinit();
        return .{ .failed = .host_unavailable };
    }
    return .{ .selected = owned };
}

/// Connect 직전 pathname/manifest ABA gate. The caller must discard the pin on any failure.
pub fn revalidateProduct(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    pinned: *const ResolvedHostDescriptor,
    phase: attach_phase_deadline.PhaseDeadline,
) ?attach_cli.ExitCode {
    if (phase.kind != .connect_hello) return .internal;
    const fresh_result = resolveProduct(allocator, base_cache_dir, pinned.runtime_id, phase);
    var fresh = switch (fresh_result) {
        .selected => |value| value,
        .failed => |code| return code,
    };
    defer fresh.deinit();
    if (!pinEvidenceEql(pinned, &fresh)) return .denied;
    return null;
}

fn pinEvidenceEql(
    pinned: *const ResolvedHostDescriptor,
    fresh: *const ResolvedHostDescriptor,
) bool {
    return fresh.runtime_id == pinned.runtime_id and
        host_manifest.descriptorEql(fresh.descriptor(), pinned.descriptor()) and
        fresh.socket_identity.eql(pinned.socket_identity);
}

/// Fresh descriptor+socket revalidation and the one long-lived CLI transport. We compare the
/// pathname identity both before and after connect and independently validate host/build/wire
/// identity in hello. POSIX does not expose the peer socket inode through this connection, so this
/// is a same-UID accidental/ordinary ABA guard, not a defense against a malicious same-UID process.
pub fn connectPinned(
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    pinned: *const ResolvedHostDescriptor,
    intent: attach_cli.Intent,
    phase: attach_phase_deadline.PhaseDeadline,
) Connected {
    if (phase.kind != .connect_hello or phase.absolute.remainingNs() <= 0)
        return .{ .failed = .host_unavailable };
    const profile = compatibility.profileForMajor(pinned.protocol_major) orelse
        return .{ .failed = .unsupported };
    // Frozen v1's only attach schema grants controller unconditionally. Letting observer/takeover
    // intents reach that decoder would silently elevate them.
    if (profile.attach_schema == .frozen_controller_only and intent != .default_controller)
        return .{ .failed = .unsupported };
    if (revalidateProduct(allocator, base_cache_dir, pinned, phase)) |code|
        return .{ .failed = code };
    // This is the long-lived public-attach connection, not a discovery probe. No stream exists
    // until the caller constructs and binds RemoteAttachment, so advertising transfer here cannot
    // deliver a revoke before a consumer exists; it only negotiates the schema used after attach.
    const outcome = host_connect.connectDiscoveredHostProfileUntil(
        allocator,
        base_cache_dir,
        pinned.descriptor(),
        .cli_attach,
        phase,
    );
    var client = switch (outcome) {
        .connected => |value| value,
        .failed => |reason| return .{ .failed = selectedConnectExit(reason) },
    };
    // A same-major pre-transfer host can safely serve a pure observer but cannot revoke a
    // controller after another client takes over. Never acquire controller authority on that
    // profile; the CLI reports that the host must be updated before raw-mode mutation begins.
    if (profile.attach_schema == .granted_roles and
        !client.attachment_capabilities.negotiated_controller_transfer and
        intent != .read_only)
    {
        client.deinit();
        return .{ .failed = .unsupported };
    }
    if (phase.absolute.remainingNs() <= 0) {
        client.deinit();
        return .{ .failed = .host_unavailable };
    }
    const observed_after = observeSocket(pinned.endpoint);
    if (phase.absolute.remainingNs() <= 0) {
        client.deinit();
        return .{ .failed = .host_unavailable };
    }
    const after = switch (observed_after) {
        .identity => |value| value,
        .absent => {
            client.deinit();
            return .{ .failed = .host_unavailable };
        },
        .denied => {
            client.deinit();
            return .{ .failed = if (phase.absolute.remainingNs() <= 0)
                .host_unavailable
            else
                .denied };
        },
    };
    if (!after.eql(pinned.socket_identity)) {
        client.deinit();
        return .{ .failed = .denied };
    }
    if (phase.absolute.remainingNs() <= 0) {
        client.deinit();
        return .{ .failed = .host_unavailable };
    }
    return .{ .client = client };
}

const SocketObservation = union(enum) {
    identity: SocketIdentity,
    absent,
    denied,
};

fn observeSocket(endpoint: []const u8) SocketObservation {
    var path_buf: [host_manifest.max_endpoint_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{endpoint}) catch return .denied;
    var stat: posix.Stat = undefined;
    const rc = c.fstatat(posix.AT.FDCWD, path.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW);
    if (rc != 0) return switch (posix.errno(rc)) {
        .NOENT, .NOTDIR => .absent,
        else => .denied,
    };
    if (!posix.S.ISSOCK(stat.mode) or stat.uid != c.getuid() or (stat.mode & 0o777) != 0o600)
        return .denied;
    return .{ .identity = .{ .dev = stat.dev, .ino = stat.ino } };
}

fn registryRootAbsent(session_dir: [:0]const u8) bool {
    var stat: posix.Stat = undefined;
    if (c.fstatat(posix.AT.FDCWD, session_dir.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return posix.errno(-1) == .NOENT;
    var hosts_buf: [640]u8 = undefined;
    const hosts = host_manifest.hostsRootPathIn(&hosts_buf, session_dir) catch return false;
    if (c.fstatat(posix.AT.FDCWD, hosts.ptr, &stat, posix.AT.SYMLINK_NOFOLLOW) != 0)
        return posix.errno(-1) == .NOENT;
    return false;
}

fn connectFailure(reason: host_connect.FailureReason) attach_cli.Probe {
    return switch (reason) {
        .out_of_memory => .out_of_memory,
        .endpoint_denied, .invalid_endpoint, .invalid_manifest, .stale_manifest => .denied,
        .incompatible_version, .handshake_failed, .protocol_error => .protocol,
        .startup_timeout, .deadline_exceeded => .host_unavailable,
        .resource_exhausted, .transient_timeout => .busy,
        .unauthorized => .denied,
        .host_gone, .launch_failed => .host_unavailable,
    };
}

fn selectedConnectExit(reason: host_connect.FailureReason) attach_cli.ExitCode {
    return switch (reason) {
        .transient_timeout, .startup_timeout, .host_gone, .launch_failed => .host_unavailable,
        else => probeExit(connectFailure(reason)),
    };
}

fn probeExit(probe: attach_cli.Probe) attach_cli.ExitCode {
    return switch (probe) {
        .match => .success,
        .runtime_not_found => .runtime_not_found,
        .host_unavailable => .host_unavailable,
        .denied => .denied,
        .busy => .busy,
        .protocol => .protocol,
        .out_of_memory => .internal,
    };
}

fn decodeMembership(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    runtime_id: u128,
) attach_cli.Probe {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    }) catch |err| return if (err == error.OutOfMemory) .out_of_memory else .protocol;
    defer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 1) return .protocol;
    const root = parsed.value.object;
    if (root.get("error")) |value| {
        if (value != .string) return .protocol;
        return if (std.mem.eql(u8, value.string, "runtime_not_found"))
            .runtime_not_found
        else if (std.mem.eql(u8, value.string, "unauthorized"))
            .denied
        else
            .protocol;
    }
    const result_value = root.get("result") orelse return .protocol;
    if (result_value != .object or result_value.object.count() != 6) return .protocol;
    const result = result_value.object;
    const id_value = result.get("runtime_id") orelse return .protocol;
    if (id_value != .string or id_value.string.len != 32) return .protocol;
    for (id_value.string) |byte|
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return .protocol;
    const decoded = std.fmt.parseInt(u128, id_value.string, 16) catch return .protocol;
    const cols = jsonU64(result.get("cols") orelse return .protocol) orelse return .protocol;
    const rows = jsonU64(result.get("rows") orelse return .protocol) orelse return .protocol;
    _ = jsonU64(result.get("resize_generation") orelse return .protocol) orelse return .protocol;
    const has_controller = result.get("has_controller") orelse return .protocol;
    if (has_controller != .bool) return .protocol;
    _ = jsonU64(result.get("observer_count") orelse return .protocol) orelse return .protocol;
    if (cols == 0 or cols > std.math.maxInt(u16) or rows == 0 or rows > std.math.maxInt(u16))
        return .protocol;
    return if (decoded == runtime_id) .match else .protocol;
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |text| blk: {
            if (text.len == 0 or (text.len > 1 and text[0] == '0')) break :blk null;
            for (text) |byte| if (!std.ascii.isDigit(byte)) break :blk null;
            break :blk std.fmt.parseInt(u64, text, 10) catch null;
        },
        else => null,
    };
}

fn testPhase(kind: attach_phase_deadline.Kind) !attach_phase_deadline.PhaseDeadline {
    return attach_phase_deadline.PhaseDeadline.start(std.testing.io, kind);
}

test "product resolver rejects expired and wrong phases before discovery or connect" {
    const Clock = struct {
        now: i128 = 10,

        fn read(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now;
        }
    };
    var clock = Clock{};
    const absolute = @import("client_deadline.zig").AbsoluteDeadline.fromInjected(
        .{ .context = &clock, .now_ns = Clock.read },
        10,
    );
    const expired = attach_phase_deadline.PhaseDeadline.fromAbsolute(.resolve, absolute);
    try std.testing.expectEqual(
        attach_cli.ExitCode.host_unavailable,
        resolveProduct(std.testing.allocator, "/definitely/not/read", 1, expired).failed,
    );
    const wrong = attach_phase_deadline.PhaseDeadline.fromAbsolute(.attach_snapshot, absolute);
    try std.testing.expectEqual(
        attach_cli.ExitCode.denied,
        resolveProduct(std.testing.allocator, "/definitely/not/read", 1, wrong).failed,
    );
}

test "resolved host descriptor owns discovery strings and pins socket identity" {
    var build = [_]u8{'b'} ** 71;
    @memcpy(build[0..7], "sha256:");
    var endpoint = [_]u8{0} ** 32;
    @memcpy(endpoint[0..14], "/tmp/test.sock");
    var pinned = try ResolvedHostDescriptor.init(
        std.testing.allocator,
        0xaa,
        .{
            .host_id = 0xaa,
            .build_id = &build,
            .protocol_major = 2,
            .screen_codec_version = 2,
            .upgrade_epoch = 3,
            .lifecycle = .ready,
            .endpoint = endpoint[0..14],
        },
        .{ .dev = 7, .ino = 11 },
    );
    defer pinned.deinit();
    build[7] = 'c';
    endpoint[5] = 'X';
    try std.testing.expectEqual(@as(u8, 'b'), pinned.build_id[7]);
    try std.testing.expectEqualStrings("/tmp/test.sock", pinned.endpoint);
    try std.testing.expect(pinned.socket_identity.eql(.{ .dev = 7, .ino = 11 }));

    var replaced = try ResolvedHostDescriptor.init(
        std.testing.allocator,
        pinned.runtime_id,
        pinned.descriptor(),
        .{ .dev = 7, .ino = 12 },
    );
    defer replaced.deinit();
    try std.testing.expect(!pinEvidenceEql(&pinned, &replaced));
}

fn checkResolvedHostAllocation(allocator: std.mem.Allocator) !void {
    var pinned = try ResolvedHostDescriptor.init(
        allocator,
        0xaa,
        .{
            .host_id = 0xbb,
            .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            .protocol_major = 2,
            .screen_codec_version = 2,
            .upgrade_epoch = 1,
            .lifecycle = .ready,
            .endpoint = "/tmp/test.sock",
        },
        .{ .dev = 7, .ino = 11 },
    );
    pinned.deinit();
}

test "resolved host descriptor allocation is leak-free at every fail index" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkResolvedHostAllocation,
        .{},
    );
}

test "previous granted host defers observer and takeover policy to negotiated reconnect" {
    var pinned = try ResolvedHostDescriptor.init(
        std.testing.allocator,
        0xaa,
        .{
            .host_id = 0xaa,
            .build_id = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            .protocol_major = 1,
            .screen_codec_version = 1,
            .upgrade_epoch = 1,
            .lifecycle = .ready,
            .endpoint = "/tmp/not-opened.sock",
        },
        .{ .dev = 7, .ino = 11 },
    );
    defer pinned.deinit();
    inline for (.{ attach_cli.Intent.read_only, attach_cli.Intent.take_over }) |intent| {
        const result = connectPinned(std.testing.allocator, "/tmp", &pinned, intent, try testPhase(.connect_hello));
        try std.testing.expectEqual(attach_cli.ExitCode.host_unavailable, result.failed);
    }
}

test "membership decoder accepts only exact runtime or exact absence envelope" {
    try std.testing.expectEqual(
        attach_cli.Probe.match,
        decodeMembership(
            std.testing.allocator,
            "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":80,\"rows\":24,\"resize_generation\":0,\"has_controller\":false,\"observer_count\":0}}",
            0xaa,
        ),
    );
    try std.testing.expectEqual(
        attach_cli.Probe.runtime_not_found,
        decodeMembership(
            std.testing.allocator,
            "{\"error\":\"runtime_not_found\"}",
            0xaa,
        ),
    );
    const invalid = [_][]const u8{
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000bb\"}}",
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":80,\"rows\":24,\"resize_generation\":0,\"has_controller\":false}}",
        "{\"error\":\"runtime_not_found\",\"extra\":1}",
        "{\"error\":\"future_error\"}",
        "{\"result\":{\"runtime_id\":\"AA\"}}",
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000AA\"}}",
    };
    for (invalid) |bytes| try std.testing.expectEqual(
        attach_cli.Probe.protocol,
        decodeMembership(std.testing.allocator, bytes, 0xaa),
    );
}

fn terminateAndReapFixtureChild(pid: c.pid_t) bool {
    const kill_rc = c.kill(pid, posix.SIG.TERM);
    if (kill_rc != 0 and posix.errno(kill_rc) != .SRCH) return false;
    while (true) {
        var status: c_int = undefined;
        const waited = c.waitpid(pid, &status, 0);
        if (waited == pid) {
            const unsigned: c_uint = @bitCast(status);
            return c.W.IFEXITED(unsigned) or c.W.IFSIGNALED(unsigned);
        }
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        return false;
    }
}

test "product resolver discovers and pins the one host that owns a live runtime" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const daemon = @import("daemon.zig");
    const short_endpoint = @import("short_endpoint.zig");
    const testing = std.testing;
    const host_id = (@as(u128, @intCast(c.getpid())) << 64) | 0xa771;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(testing.io, &base_buf);
    if (base_len == base_buf.len) return error.SkipZigTest;
    base_buf[base_len] = 0;
    const base: [:0]const u8 = base_buf[0..base_len :0];
    const no_host = resolveProduct(testing.allocator, base, 1, try testPhase(.resolve));
    try testing.expectEqual(attach_cli.ExitCode.host_unavailable, no_host.failed);
    var session_buf: [256]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        daemon.runSessionHostWithIdentity(
            std.heap.page_allocator,
            testing.io,
            session_dir,
            endpoint,
            host_id,
        ) catch {};
        std.c._exit(0);
    }
    defer if (!terminateAndReapFixtureChild(child))
        @panic("failed to reap first resolver fixture host");

    var owner_client = blk: {
        var attempt: usize = 0;
        while (attempt < 150) : (attempt += 1) {
            switch (host_connect.connectExistingHost(testing.allocator, base, host_id)) {
                .connected => |client| break :blk client,
                .failed => {},
            }
            _ = usleep(20_000);
        }
        return error.TestUnexpectedResult;
    };
    defer owner_client.deinit();
    const spawn = try owner_client.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}",
    );
    defer testing.allocator.free(spawn);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, spawn, .{});
    defer parsed.deinit();
    const runtime_text = parsed.value.object.get("result").?.object.get("runtime_id").?.string;
    const runtime_id = try std.fmt.parseInt(u128, runtime_text, 16);

    // A real second host whose reactor is saturated cannot complete a membership handshake. Even
    // though the first host matches, all-or-none resolution must publish the observed protocol
    // inconclusive (which outranks busy) and must not return a long connection.
    const connection_slot = @import("connection_slot.zig");
    const second_host_id = host_id + 1;
    var second_endpoint_buf: [128]u8 = undefined;
    const second_endpoint = try short_endpoint.currentSocketPathIn(
        &second_endpoint_buf,
        second_host_id,
    );
    const second_child = c.fork();
    if (second_child < 0) return error.SkipZigTest;
    if (second_child == 0) {
        daemon.runSessionHostWithIdentity(
            std.heap.page_allocator,
            testing.io,
            session_dir,
            second_endpoint,
            second_host_id,
        ) catch {};
        std.c._exit(0);
    }
    defer if (!terminateAndReapFixtureChild(second_child))
        @panic("failed to reap second resolver fixture host");
    var blockers = [_]?@import("client.zig").Client{null} ** connection_slot.max_connections;
    defer for (&blockers) |*blocker| {
        if (blocker.*) |*client| client.deinit();
        blocker.* = null;
    };
    for (&blockers) |*blocker| {
        var connect_attempt: usize = 0;
        while (connect_attempt < 150) : (connect_attempt += 1) {
            switch (host_connect.connectExistingHost(
                testing.allocator,
                base,
                second_host_id,
            )) {
                .connected => |client| {
                    blocker.* = client;
                    break;
                },
                .failed => {},
            }
            _ = usleep(20_000);
        }
        if (blocker.* == null) return error.TestUnexpectedResult;
    }
    const incomplete = resolveProduct(testing.allocator, base, runtime_id, try testPhase(.resolve));
    try testing.expectEqual(attach_cli.ExitCode.protocol, incomplete.failed);
    for (&blockers) |*blocker| {
        if (blocker.*) |*client| client.deinit();
        blocker.* = null;
    }
    const recovery_phase = try testPhase(.resolve);
    var pinned = retry: {
        var attempt: usize = 0;
        while (attempt < 150) : (attempt += 1) {
            const resolved = resolveProduct(testing.allocator, base, runtime_id, recovery_phase);
            switch (resolved) {
                .selected => |value| break :retry value,
                .failed => {},
            }
            _ = usleep(20_000);
        }
        return error.TestUnexpectedResult;
    };
    defer pinned.deinit();
    try testing.expectEqual(host_id, pinned.host_id);
    try testing.expect(revalidateProduct(testing.allocator, base, &pinned, try testPhase(.connect_hello)) == null);

    // Replace only the pathname socket object while the original daemon and manifest remain live.
    // The pinned positive result must not follow the path to a different inode.
    var old_endpoint_buf: [160]u8 = undefined;
    const old_endpoint = try std.fmt.bufPrintZ(
        &old_endpoint_buf,
        "{s}.pinned",
        .{endpoint},
    );
    try testing.expectEqual(@as(c_int, 0), c.rename(endpoint.ptr, old_endpoint.ptr));
    var original_restored = false;
    errdefer if (!original_restored) {
        _ = c.unlink(endpoint.ptr);
        _ = c.rename(old_endpoint.ptr, endpoint.ptr);
    };
    const replacement_fd = c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (replacement_fd < 0) return error.TestUnexpectedResult;
    var replacement_open = true;
    defer {
        if (replacement_open) _ = c.close(replacement_fd);
    }
    var replacement_addr = posix.sockaddr.un{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&replacement_addr.path, 0);
    @memcpy(replacement_addr.path[0..endpoint.len], endpoint);
    try testing.expectEqual(
        @as(c_int, 0),
        c.bind(
            replacement_fd,
            @ptrCast(&replacement_addr),
            @sizeOf(posix.sockaddr.un),
        ),
    );
    try testing.expectEqual(@as(c_int, 0), c.chmod(endpoint.ptr, 0o600));
    try testing.expectEqual(@as(c_int, 0), c.listen(replacement_fd, 8));
    const proxy_child = c.fork();
    if (proxy_child < 0) return error.TestUnexpectedResult;
    if (proxy_child == 0) runTestSocketProxy(replacement_fd, old_endpoint);
    var proxy_live = true;
    defer {
        if (proxy_live and !terminateAndReapFixtureChild(proxy_child))
            @panic("failed to reap resolver proxy fixture");
    }
    const replacement_identity = switch (observeSocket(endpoint)) {
        .identity => |identity| identity,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(!replacement_identity.eql(pinned.socket_identity));
    try testing.expectEqual(
        attach_cli.ExitCode.denied,
        revalidateProduct(testing.allocator, base, &pinned, try testPhase(.connect_hello)).?,
    );
    try testing.expect(terminateAndReapFixtureChild(proxy_child));
    proxy_live = false;
    _ = c.close(replacement_fd);
    replacement_open = false;
    try testing.expectEqual(@as(c_int, 0), c.unlink(endpoint.ptr));
    try testing.expectEqual(@as(c_int, 0), c.rename(old_endpoint.ptr, endpoint.ptr));
    original_restored = true;
    try testing.expect(revalidateProduct(testing.allocator, base, &pinned, try testPhase(.connect_hello)) == null);

    const attached = connectPinned(testing.allocator, base, &pinned, .default_controller, try testPhase(.connect_hello));
    var long_client = switch (attached) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer long_client.deinit();
    try testing.expectEqual(host_id, long_client.host_id);
    try testing.expect(long_client.attachment_capabilities.peer_attach_generation);
    try testing.expect(long_client.attachment_capabilities.negotiated_controller_transfer);

    const controller_params = try remote_attachment.attachParams(
        testing.allocator,
        runtime_id,
        .controller,
    );
    defer testing.allocator.free(controller_params);
    const controller_response = try long_client.call("runtime.attach", controller_params);
    defer testing.allocator.free(controller_response);
    var controller_decoded = try remote_attachment.decodeAttachResponse(
        testing.allocator,
        controller_response,
        runtime_id,
        .controller,
        .{
            .generation_schema = .granted_with_generation,
            .metadata_support = long_client.metadata_support,
        },
    );
    defer controller_decoded.deinit();
    const controller_grant = switch (controller_decoded) {
        .accepted => |*accepted| accepted,
        .wire_error => return error.TestUnexpectedResult,
    };
    var old_attachment = remote_attachment.RemoteAttachment.init(
        testing.allocator,
        controller_grant.state,
    );
    defer old_attachment.deinit();

    const takeover_connection = connectPinned(
        testing.allocator,
        base,
        &pinned,
        .take_over,
        try testPhase(.connect_hello),
    );
    var takeover_client = switch (takeover_connection) {
        .client => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer takeover_client.deinit();
    const observer_params = try remote_attachment.attachParams(
        testing.allocator,
        runtime_id,
        .observer,
    );
    defer testing.allocator.free(observer_params);
    const observer_response = try takeover_client.call("runtime.attach", observer_params);
    defer testing.allocator.free(observer_response);
    var observer_decoded = try remote_attachment.decodeAttachResponse(
        testing.allocator,
        observer_response,
        runtime_id,
        .observer,
        .{
            .generation_schema = .granted_with_generation,
            .metadata_support = takeover_client.metadata_support,
        },
    );
    defer observer_decoded.deinit();
    const observer_grant = switch (observer_decoded) {
        .accepted => |*accepted| accepted,
        .wire_error => return error.TestUnexpectedResult,
    };
    var new_attachment = remote_attachment.RemoteAttachment.init(
        testing.allocator,
        observer_grant.state,
    );
    defer new_attachment.deinit();
    const status_params = try remote_attachment.statusParams(
        testing.allocator,
        new_attachment.streamId(),
    );
    defer testing.allocator.free(status_params);
    const status_response = try takeover_client.call("controller.status", status_params);
    defer testing.allocator.free(status_response);
    const status = try remote_attachment.decodeStatus(
        testing.allocator,
        status_response,
        &new_attachment.state,
    );
    const takeover_params = try remote_attachment.takeoverParams(
        testing.allocator,
        new_attachment.streamId(),
        status.controller_generation,
    );
    defer testing.allocator.free(takeover_params);
    const takeover_response = try takeover_client.call(
        "controller.takeover",
        takeover_params,
    );
    defer testing.allocator.free(takeover_response);
    try remote_attachment.decodeTakeover(
        testing.allocator,
        takeover_response,
        &new_attachment.state,
        status.controller_generation,
    );
    try testing.expect(new_attachment.allowsMutation());

    var revoked = false;
    var revoke_attempt: usize = 0;
    while (revoke_attempt < 50 and !revoked) : (revoke_attempt += 1) {
        while (try long_client.takeEventForStream(old_attachment.streamId())) |event| {
            defer long_client.releaseEvent(event);
            const classified = runtime_event_types.classifyEventView(
                .{
                    .runtime_id = old_attachment.state.runtime_id,
                    .stream_id = old_attachment.state.stream_id,
                },
                .{
                    .role = if (old_attachment.state.role == .controller)
                        .controller
                    else
                        .observer,
                    .generation = .{
                        .tracked = old_attachment.state.controller_generation,
                    },
                },
                .{
                    .expected_major = long_client.wire_major,
                    .metadata_support = long_client.metadata_support,
                    .verdict = event.preflight orelse
                        runtime_event_wire.preflightEvent(event.payload, .{}),
                },
                .{
                    .major = event.header.major,
                    .kind = event.header.kind,
                    .stream_id = event.header.stream_id,
                    .request_id = event.header.request_id,
                    .flags = event.header.flags,
                    .payload_len = event.header.payload_len,
                    .payload = event.payload,
                },
            );
            const validated = switch (classified) {
                .accepted => |value| value,
                .violation => return error.TestUnexpectedResult,
            };
            switch (validated) {
                .revoked => |generation| {
                    try old_attachment.applyValidatedRevoked(generation);
                    revoked = true;
                    break;
                },
                else => {},
            }
        }
        if (revoked) break;
        if (try long_client.readStreamBatch(
            old_attachment.streamId(),
        )) |batch| batch.deinit();
    }
    try testing.expect(revoked);
    try testing.expect(!old_attachment.allowsMutation());
    try testing.expectEqual(
        new_attachment.state.controller_generation,
        old_attachment.state.controller_generation,
    );

    var missing = resolveProduct(testing.allocator, base, runtime_id + 1, try testPhase(.resolve));
    switch (missing) {
        .failed => |code| try testing.expectEqual(attach_cli.ExitCode.runtime_not_found, code),
        .selected => |*unexpected| {
            unexpected.deinit();
            return error.TestUnexpectedResult;
        },
    }

    // Keep manifest and socket unchanged while membership disappears. This proves revalidation
    // repeats runtime.get instead of trusting only the pinned descriptor/path identity.
    var runtime_id_text: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&runtime_id_text, "{x:0>32}", .{runtime_id});
    var terminate_buf: [64]u8 = undefined;
    const terminate_params = try std.fmt.bufPrint(
        &terminate_buf,
        "{{\"runtime_id\":\"{s}\"}}",
        .{&runtime_id_text},
    );
    const terminated = try owner_client.call("runtime.terminate", terminate_params);
    testing.allocator.free(terminated);
    try testing.expectEqual(
        attach_cli.ExitCode.runtime_not_found,
        revalidateProduct(testing.allocator, base, &pinned, try testPhase(.connect_hello)).?,
    );
    const stale_connect = connectPinned(
        testing.allocator,
        base,
        &pinned,
        .default_controller,
        try testPhase(.connect_hello),
    );
    try testing.expectEqual(attach_cli.ExitCode.runtime_not_found, stale_connect.failed);

    // A pinned positive result must not survive endpoint or manifest disappearance.
    try testing.expectEqual(@as(c_int, 0), c.unlink(endpoint.ptr));
    try testing.expectEqual(
        attach_cli.ExitCode.host_unavailable,
        revalidateProduct(testing.allocator, base, &pinned, try testPhase(.connect_hello)).?,
    );
    var manifest_buf: [832]u8 = undefined;
    const manifest_path = try host_manifest.manifestPathIn(&manifest_buf, session_dir, host_id);
    try testing.expectEqual(@as(c_int, 0), c.unlink(manifest_path.ptr));
    try testing.expectEqual(
        attach_cli.ExitCode.denied,
        revalidateProduct(testing.allocator, base, &pinned, try testPhase(.connect_hello)).?,
    );
}
