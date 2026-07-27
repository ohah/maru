//! Public attach pre-raw transaction.
//!
//! This owner consumes the four bounded phases and publishes a screen-bearing attachment only
//! after resolve, pinned connect, attach snapshot and optional takeover are fully verified. It
//! never enters raw mode or emits ANSI; every failure closes the socket so host-side attachment
//! cleanup is driven by EOF rather than an ambiguous compensating detach RPC.

const std = @import("std");
const attach_cli = @import("maru").cli.attach;
const attach_phase_deadline = @import("attach_phase_deadline.zig");
const attach_product_resolver = @import("attach_product_resolver.zig");
const client_mod = @import("client.zig");
const compatibility = @import("compatibility.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_attachment = @import("remote_attachment.zig");
const socket_server = @import("socket_server.zig");
extern "c" fn usleep(usec: c_uint) c_int;

pub const Prepared = struct {
    client: client_mod.Client,
    attachment: remote_attachment.RemoteAttachment,

    pub fn deinit(self: *Prepared) void {
        self.attachment.deinit();
        self.client.deinit();
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    prepared: Prepared,
    failed: attach_cli.ExitCode,
};

pub fn prepare(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_cache_dir: []const u8,
    request: attach_cli.Request,
) Result {
    return prepareWithTransition(
        allocator,
        io,
        base_cache_dir,
        request,
        enterExternalMode,
    );
}

const ModeTransition = *const fn (*client_mod.Client) client_mod.EnterExternalModeError!void;

fn enterExternalMode(client: *client_mod.Client) client_mod.EnterExternalModeError!void {
    return client.enterExternalMode();
}

fn prepareWithTransition(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_cache_dir: []const u8,
    request: attach_cli.Request,
    transition: ModeTransition,
) Result {
    const resolve_phase = attach_phase_deadline.PhaseDeadline.start(io, .resolve) catch
        return .{ .failed = .internal };
    const resolved = attach_product_resolver.resolveProduct(
        allocator,
        base_cache_dir,
        request.runtime_id,
        resolve_phase,
    );
    var pinned = switch (resolved) {
        .selected => |value| value,
        .failed => |code| return .{ .failed = code },
    };
    defer pinned.deinit();

    const connect_phase = attach_phase_deadline.PhaseDeadline.start(io, .connect_hello) catch
        return .{ .failed = .internal };
    const connected = attach_product_resolver.connectPinned(
        allocator,
        base_cache_dir,
        &pinned,
        request.intent,
        connect_phase,
    );
    var client = switch (connected) {
        .client => |value| value,
        .failed => |code| return .{ .failed = code },
    };
    var client_owned = true;
    defer if (client_owned) client.deinit();

    const requested_mode: remote_attachment.Mode = switch (request.intent) {
        .read_only, .take_over => .observer,
        .default_controller => .controller,
    };
    const attach_phase = attach_phase_deadline.PhaseDeadline.start(io, .attach_snapshot) catch
        return failClient(&client, .internal);
    const attach_stage = attachSnapshot(
        allocator,
        io,
        &client,
        request.runtime_id,
        requested_mode,
        attach_phase,
    );
    var attachment = switch (attach_stage) {
        .attachment => |value| value,
        .failed => |code| return .{ .failed = code },
    };
    var attachment_owned = true;
    defer if (attachment_owned) attachment.deinit();

    if (request.intent == .take_over) {
        const code = performTakeover(allocator, io, &client, &attachment);
        if (code) |failed| return failClient(&client, failed);
    }
    if (publishGate(&client, &attachment)) |failed|
        return failClient(&client, failed);
    transition(&client) catch |err|
        return failClient(&client, transitionExit(err));

    attachment_owned = false;
    client_owned = false;
    return .{ .prepared = .{
        .client = client,
        .attachment = attachment,
    } };
}

fn failExternalModeTransition(_: *client_mod.Client) client_mod.EnterExternalModeError!void {
    return error.FlagFailed;
}

/// Final publication depends only on authority evidence buffered on the live connection. Each
/// completed phase has already checked its own deadline immediately before committing its output;
/// rechecking an older phase here would incorrectly collapse the four independent budgets.
fn publishGate(
    client: *client_mod.Client,
    attachment: *const remote_attachment.RemoteAttachment,
) ?attach_cli.ExitCode {
    client.refreshBufferedAuthorityEvidence() catch |err|
        return deadlineCallExit(err, .protocol);
    if (client.hasBufferedControllerRevokeForStream(attachment.streamId())) return .denied;
    return null;
}

const AttachStage = union(enum) {
    attachment: remote_attachment.RemoteAttachment,
    failed: attach_cli.ExitCode,
};

fn attachSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *client_mod.Client,
    runtime_id: u128,
    requested_mode: remote_attachment.Mode,
    phase: attach_phase_deadline.PhaseDeadline,
) AttachStage {
    if (phase.kind != .attach_snapshot or phase.absolute.remainingNs() <= 0)
        return failAttachStage(client, .protocol);
    const attach_params = remote_attachment.attachParams(
        allocator,
        runtime_id,
        requested_mode,
    ) catch return failAttachStage(client, .internal);
    defer allocator.free(attach_params);
    const attach_response = client.callUntil(
        "runtime.attach",
        attach_params,
        phase.absolute,
    ) catch |err| return failAttachStage(client, deadlineCallExit(err, .protocol));
    defer allocator.free(attach_response);
    if (responseErrorExit(allocator, attach_response)) |code|
        return failAttachStage(client, code);

    const profile = compatibility.profileForMajor(client.wire_major) orelse
        return failAttachStage(client, .unsupported);
    const accepted = switch (profile.attach_schema) {
        .frozen_controller_only => remote_attachment.decodeFrozenV1ControllerAttach(
            allocator,
            attach_response,
            runtime_id,
        ),
        .granted_roles => remote_attachment.decodeAttachForCapabilities(
            allocator,
            attach_response,
            runtime_id,
            requested_mode,
            client.attachment_capabilities.peer_attach_generation,
        ),
    } catch |err| return failAttachStage(client, decodeExit(err));

    var attachment = remote_attachment.RemoteAttachment.init(allocator, accepted.state);
    var owned = true;
    defer if (owned) attachment.deinit();
    const snapshot = client.readSnapshotUntil(
        attachment.streamId(),
        phase.absolute,
    ) catch |err| return failAttachStage(client, deadlineCallExit(err, .protocol));
    defer allocator.free(snapshot);
    attachment.initScreen(client.screen_codec_version) catch
        return failAttachStage(client, .internal);
    attachment.screen.?.viewport_scrolled_known = client.screen_viewport_scrolled_v1;
    attachment.screen.?.applySnapshot(snapshot, io) catch |err|
        return failAttachStage(client, switch (err) {
            error.OutOfMemory => .internal,
            else => .protocol,
        });
    if (phase.absolute.remainingNs() <= 0)
        return failAttachStage(client, .protocol);
    owned = false;
    return .{ .attachment = attachment };
}

fn performTakeover(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *client_mod.Client,
    attachment: *remote_attachment.RemoteAttachment,
) ?attach_cli.ExitCode {
    if (!client.attachment_capabilities.negotiated_controller_transfer)
        return .unsupported;
    const phase = attach_phase_deadline.PhaseDeadline.start(io, .status_takeover) catch
        return .internal;
    return performTakeoverInPhase(allocator, client, attachment, phase);
}

fn performTakeoverInPhase(
    allocator: std.mem.Allocator,
    client: *client_mod.Client,
    attachment: *remote_attachment.RemoteAttachment,
    phase: attach_phase_deadline.PhaseDeadline,
) ?attach_cli.ExitCode {
    if (phase.kind != .status_takeover or phase.absolute.remainingNs() <= 0)
        return .protocol;
    const status_params = remote_attachment.statusParams(
        allocator,
        attachment.streamId(),
    ) catch return .internal;
    defer allocator.free(status_params);
    const status_response = client.callUntil(
        "controller.status",
        status_params,
        phase.absolute,
    ) catch |err| return deadlineCallExit(err, .protocol);
    defer allocator.free(status_response);
    if (responseErrorExit(allocator, status_response)) |code| return code;

    var scratch = attachment.state;
    _ = remote_attachment.decodeStatus(
        allocator,
        status_response,
        &scratch,
    ) catch |err| return decodeExit(err);
    const takeover_params = remote_attachment.takeoverParams(
        allocator,
        scratch.stream_id,
        scratch.controller_generation,
    ) catch return .internal;
    defer allocator.free(takeover_params);
    const takeover_response = client.callUntil(
        "controller.takeover",
        takeover_params,
        phase.absolute,
    ) catch |err| return deadlineCallExit(err, .protocol);
    defer allocator.free(takeover_response);
    if (responseErrorExit(allocator, takeover_response)) |code| return code;
    remote_attachment.decodeTakeover(
        allocator,
        takeover_response,
        &scratch,
        scratch.controller_generation,
    ) catch |err| return decodeExit(err);
    if (phase.absolute.remainingNs() <= 0) return .protocol;
    client.refreshBufferedAuthorityEvidence() catch |err|
        return deadlineCallExit(err, .protocol);
    if (client.hasBufferedControllerRevokeForStream(scratch.stream_id)) return .denied;
    if (phase.absolute.remainingNs() <= 0) return .protocol;
    attachment.state = scratch;
    return null;
}

fn responseErrorExit(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ?attach_cli.ExitCode {
    const wire = remote_attachment.decodeWireError(allocator, bytes) catch |err|
        return decodeExit(err);
    const code = wire orelse return null;
    return attach_cli.remoteExitCode(code);
}

fn decodeExit(err: remote_attachment.DecodeError) attach_cli.ExitCode {
    return switch (err) {
        error.OutOfMemory => .internal,
        error.Malformed => .protocol,
    };
}

fn deadlineCallExit(
    err: client_mod.DeadlineClientError,
    timeout: attach_cli.ExitCode,
) attach_cli.ExitCode {
    return switch (err) {
        error.DeadlineExceeded => timeout,
        error.OutOfMemory => .internal,
        error.EndpointAbsent, error.EndpointTransient, error.ConnectionClosed, error.WriteFailed => timeout,
        error.EndpointDenied, error.Unauthorized => .denied,
        error.AdminBusy => .busy,
        error.IncompatibleVersion => .unsupported,
        error.HandshakeFailed, error.ProtocolError, error.EventQueueFull, error.ExternalMode => .protocol,
    };
}

fn transitionExit(err: client_mod.EnterExternalModeError) attach_cli.ExitCode {
    return switch (err) {
        error.Busy => .busy,
        error.OutOfMemory, error.FlagFailed, error.AlreadyExternal => .internal,
        error.ConnectionClosed => .protocol,
    };
}

fn failClient(client: *client_mod.Client, code: attach_cli.ExitCode) Result {
    client.failClosed();
    return .{ .failed = code };
}

fn failAttachStage(client: *client_mod.Client, code: attach_cli.ExitCode) AttachStage {
    client.failClosed();
    return .{ .failed = code };
}

test "external attach maps exact takeover wire errors" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ "invalid_generation", attach_cli.ExitCode.busy },
        .{ "resource_exhausted", attach_cli.ExitCode.busy },
        .{ "unauthorized", attach_cli.ExitCode.denied },
        .{ "runtime_not_found", attach_cli.ExitCode.runtime_not_found },
        .{ "invalid_request", attach_cli.ExitCode.protocol },
        .{ "internal", attach_cli.ExitCode.internal },
    };
    inline for (cases) |case| {
        var buffer: [96]u8 = undefined;
        const json = try std.fmt.bufPrint(&buffer, "{{\"error\":\"{s}\"}}", .{case[0]});
        try std.testing.expectEqual(case[1], responseErrorExit(allocator, json).?);
    }
    try std.testing.expectEqual(
        attach_cli.ExitCode.protocol,
        responseErrorExit(allocator, "{\"error\":\"unknown\"}").?,
    );
}

test "external attach maps mode transition failures without ambiguity" {
    try std.testing.expectEqual(attach_cli.ExitCode.busy, transitionExit(error.Busy));
    try std.testing.expectEqual(attach_cli.ExitCode.internal, transitionExit(error.OutOfMemory));
    try std.testing.expectEqual(attach_cli.ExitCode.internal, transitionExit(error.FlagFailed));
    try std.testing.expectEqual(attach_cli.ExitCode.internal, transitionExit(error.AlreadyExternal));
    try std.testing.expectEqual(attach_cli.ExitCode.protocol, transitionExit(error.ConnectionClosed));
}

test "external attach transition failure closes without follow-up wire" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const c = std.c;
    const posix = std.posix;
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = fds[0],
        .host_id = 1,
        .wire_major = protocol.version_major,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    const result = failClient(&client, transitionExit(error.FlagFailed));
    defer client.deinit();
    try std.testing.expectEqual(
        attach_cli.ExitCode.internal,
        switch (result) {
            .failed => |code| code,
            .prepared => return error.TestUnexpectedResult,
        },
    );
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(fds[1], &byte, byte.len));
}

test "external publish does not reuse an expired prior phase budget" {
    const Clock = struct {
        now_ns: i128 = 0,

        fn now(context: *anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.now_ns;
        }
    };
    var clock = Clock{};
    const old_attach_phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .attach_snapshot,
        @import("client_deadline.zig").AbsoluteDeadline.fromInjected(
            .{ .context = &clock, .now_ns = Clock.now },
            5,
        ),
    );
    var client: client_mod.Client = .{
        .allocator = std.testing.allocator,
        .fd = -1,
        .host_id = 1,
        .parser = framing.FrameParser.init(std.testing.allocator),
    };
    defer client.deinit();
    var attachment = remote_attachment.RemoteAttachment.init(std.testing.allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .controller,
        .controller_generation = 2,
    });
    defer attachment.deinit();

    clock.now_ns = old_attach_phase.absolute.expires_at_ns;
    try std.testing.expectEqual(@as(i128, 0), old_attach_phase.absolute.remainingNs());
    try std.testing.expect(publishGate(&client, &attachment) == null);
}

const SnapshotStallPeer = struct {
    response_sent: bool = false,
    eof_seen: bool = false,
    bytes_after_attach: usize = 0,

    fn run(self: *SnapshotStallPeer, fd: std.c.fd_t, response: []const u8) void {
        defer _ = std.c.close(fd);
        var header_bytes: [protocol.header_size]u8 = undefined;
        if (!readExact(fd, &header_bytes)) return;
        const header = protocol.Header.decode(&header_bytes) catch return;
        if (header.kind != .request or header.request_id != 1) return;
        const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return;
        defer std.heap.page_allocator.free(payload);
        if (!readExact(fd, payload)) return;
        if (std.mem.indexOf(u8, payload, "\"method\":\"runtime.attach\"") == null) return;
        socket_server.writeAll(fd, response) catch return;
        self.response_sent = true;

        var poll_fd = std.posix.pollfd{
            .fd = fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        };
        if (std.c.poll(@ptrCast(&poll_fd), 1, 1_000) <= 0) return;
        var extra: [4096]u8 = undefined;
        const count = std.c.read(fd, &extra, extra.len);
        if (count == 0) {
            self.eof_seen = true;
        } else if (count > 0) {
            self.bytes_after_attach = @intCast(count);
        }
    }
};

fn readExact(fd: std.c.fd_t, bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
            continue;
        }
        if (count < 0 and std.posix.errno(count) == .INTR) continue;
        return false;
    }
    return true;
}

test "external attach snapshot timeout closes by EOF without detach compensation" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    socket_server.setNoSigPipe(fds[0]);
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":7,\"controller_generation\":1,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
    );
    defer allocator.free(response);
    var peer_state = SnapshotStallPeer{};
    var peer = try std.Thread.spawn(.{}, SnapshotStallPeer.run, .{
        &peer_state,
        fds[1],
        response,
    });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    defer client.deinit();
    const absolute = try @import("client_deadline.zig").AbsoluteDeadline.after(
        std.testing.io,
        250 * std.time.ns_per_ms,
    );
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .attach_snapshot,
        absolute,
    );
    const stage = attachSnapshot(
        allocator,
        std.testing.io,
        &client,
        0xaa,
        .controller,
        phase,
    );
    try std.testing.expectEqual(attach_cli.ExitCode.protocol, stage.failed);
    peer.join();
    try std.testing.expect(peer_state.response_sent);
    try std.testing.expect(peer_state.eof_seen);
    try std.testing.expectEqual(@as(usize, 0), peer_state.bytes_after_attach);
    try std.testing.expect(client.unusable);
}

const TakeoverStallPeer = struct {
    takeover_requests: usize = 0,
    eof_seen: bool = false,
    bytes_after_takeover: usize = 0,

    fn run(self: *TakeoverStallPeer, fd: std.c.fd_t, status_response: []const u8) void {
        defer _ = std.c.close(fd);
        if (!readMethod(fd, 1, "controller.status")) return;
        socket_server.writeAll(fd, status_response) catch return;
        if (!readMethod(fd, 2, "controller.takeover")) return;
        self.takeover_requests += 1;

        var poll_fd = std.posix.pollfd{
            .fd = fd,
            .events = std.c.POLL.IN,
            .revents = 0,
        };
        if (std.c.poll(@ptrCast(&poll_fd), 1, 1_000) <= 0) return;
        var extra: [4096]u8 = undefined;
        const count = std.c.read(fd, &extra, extra.len);
        if (count == 0) {
            self.eof_seen = true;
        } else if (count > 0) {
            self.bytes_after_takeover = @intCast(count);
        }
    }
};

fn readMethod(fd: std.c.fd_t, request_id: u64, method: []const u8) bool {
    var header_bytes: [protocol.header_size]u8 = undefined;
    if (!readExact(fd, &header_bytes)) return false;
    const header = protocol.Header.decode(&header_bytes) catch return false;
    if (header.kind != .request or header.request_id != request_id) return false;
    const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return false;
    defer std.heap.page_allocator.free(payload);
    if (!readExact(fd, payload)) return false;
    return std.mem.indexOf(u8, payload, method) != null;
}

test "external takeover response timeout sends exactly one takeover and publishes no authority" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    socket_server.setNoSigPipe(fds[0]);
    const status_response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":7,\"controller_generation\":1,\"controller\":false}}",
    );
    defer allocator.free(status_response);
    var peer_state = TakeoverStallPeer{};
    var peer = try std.Thread.spawn(.{}, TakeoverStallPeer.run, .{
        &peer_state,
        fds[1],
        status_response,
    });
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
        .attachment_capabilities = .{
            .peer_attach_generation = true,
            .negotiated_controller_transfer = true,
        },
    };
    defer client.deinit();
    var attachment = remote_attachment.RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 1,
    });
    defer attachment.deinit();
    const before = attachment.state;
    const absolute = try @import("client_deadline.zig").AbsoluteDeadline.after(
        std.testing.io,
        250 * std.time.ns_per_ms,
    );
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .status_takeover,
        absolute,
    );
    try std.testing.expectEqual(
        attach_cli.ExitCode.protocol,
        performTakeoverInPhase(allocator, &client, &attachment, phase).?,
    );
    peer.join();
    try std.testing.expectEqual(@as(usize, 1), peer_state.takeover_requests);
    try std.testing.expect(peer_state.eof_seen);
    try std.testing.expectEqual(@as(usize, 0), peer_state.bytes_after_takeover);
    try std.testing.expectEqual(before, attachment.state);
    try std.testing.expect(client.unusable);
}

test "external takeover rejects a coalesced own-stream revoke before authority publish" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = std.c.close(fds[1]);
    socket_server.setNoSigPipe(fds[0]);
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 1,
        .parser = framing.FrameParser.init(allocator),
    };
    defer client.deinit();
    const status = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        "{\"result\":{\"stream_id\":7,\"controller_generation\":1,\"controller\":false}}",
    );
    defer allocator.free(status);
    const takeover = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 2 },
        "{\"result\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":2,\"reason\":\"takeover\",\"granted\":{\"observe\":true,\"input\":true,\"resize\":true}}}",
    );
    defer allocator.free(takeover);
    const revoke = try framing.encodeFrame(
        allocator,
        .{ .kind = .event, .stream_id = 7 },
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":2,\"reason\":\"takeover\"}}",
    );
    defer allocator.free(revoke);
    try client.parser.push(status);
    try client.parser.push(takeover);
    try client.parser.push(revoke);

    var attachment = remote_attachment.RemoteAttachment.init(allocator, .{
        .runtime_id = 0xaa,
        .stream_id = 7,
        .role = .observer,
        .controller_generation = 1,
    });
    defer attachment.deinit();
    const before = attachment.state;
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(
        .status_takeover,
        try @import("client_deadline.zig").AbsoluteDeadline.after(
            std.testing.io,
            std.time.ns_per_s,
        ),
    );

    try std.testing.expectEqual(
        attach_cli.ExitCode.denied,
        performTakeoverInPhase(allocator, &client, &attachment, phase).?,
    );
    try std.testing.expectEqual(before, attachment.state);
    try std.testing.expect(client.hasBufferedControllerRevokeForStream(7));
}

test "external attach product transaction resolves connects and assembles one live runtime" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const c = std.c;
    const posix = std.posix;
    const daemon = @import("daemon.zig");
    const discovery = @import("discovery.zig");
    const host_connect = @import("host_connect.zig");
    const host_manifest = @import("host_manifest.zig");
    const short_endpoint = @import("short_endpoint.zig");
    const allocator = std.testing.allocator;
    const host_id = (@as(u128, @intCast(c.getpid())) << 64) | 0xe771;
    var base_buf: [192]u8 = undefined;
    const base = try std.fmt.bufPrintZ(
        &base_buf,
        "/tmp/maru-external-attach-{d}",
        .{c.getpid()},
    );
    _ = c.mkdir(base.ptr, 0o700);
    var session_buf: [256]u8 = undefined;
    const session_dir = try discovery.sessionHostDirPath(&session_buf, base);
    try short_endpoint.prepareCurrentUserNamespace();
    var endpoint_buf: [128]u8 = undefined;
    const endpoint = try short_endpoint.currentSocketPathIn(&endpoint_buf, host_id);

    const child = c.fork();
    if (child < 0) return error.SkipZigTest;
    if (child == 0) {
        daemon.runSessionHostWithIdentity(
            std.heap.page_allocator,
            std.testing.io,
            session_dir,
            endpoint,
            host_id,
        ) catch {};
        std.c._exit(0);
    }
    defer {
        _ = c.kill(child, posix.SIG.TERM);
        var status: c_int = undefined;
        _ = c.waitpid(child, &status, 0);
        host_manifest.removeEmptyHostDirectories(session_dir, host_id);
        _ = c.rmdir(session_dir.ptr);
        _ = c.rmdir(base.ptr);
    }

    var owner = blk: {
        var attempt: usize = 0;
        while (attempt < 150) : (attempt += 1) {
            switch (host_connect.connectExistingHost(allocator, base, host_id)) {
                .connected => |client| break :blk client,
                .failed => {},
            }
            _ = usleep(20_000);
        }
        return error.TestUnexpectedResult;
    };
    defer owner.deinit();
    const spawn = try owner.call(
        "runtime.spawn",
        "{\"argv\":[\"/bin/cat\"],\"cols\":40,\"rows\":10}",
    );
    defer allocator.free(spawn);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, spawn, .{});
    defer parsed.deinit();
    const runtime_text = parsed.value.object.get("result").?.object.get("runtime_id").?.string;
    const runtime_id = try std.fmt.parseInt(u128, runtime_text, 16);

    const controller_result = prepare(allocator, std.testing.io, base, .{
        .runtime_id = runtime_id,
        .intent = .default_controller,
    });
    var controller = switch (controller_result) {
        .prepared => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    defer controller.deinit();
    try std.testing.expectEqual(runtime_id, controller.attachment.state.runtime_id);
    try std.testing.expect(controller.attachment.screen != null);
    try std.testing.expect(controller.attachment.allowsMutation());
    try std.testing.expectError(
        error.ExternalMode,
        controller.client.call("host.info", null),
    );

    const failed_transition = prepareWithTransition(
        allocator,
        std.testing.io,
        base,
        .{
            .runtime_id = runtime_id,
            .intent = .read_only,
        },
        failExternalModeTransition,
    );
    try std.testing.expectEqual(
        attach_cli.ExitCode.internal,
        switch (failed_transition) {
            .failed => |code| code,
            .prepared => |value| {
                var unexpected = value;
                unexpected.deinit();
                return error.TestUnexpectedResult;
            },
        },
    );

    const observer_result = prepare(allocator, std.testing.io, base, .{
        .runtime_id = runtime_id,
        .intent = .read_only,
    });
    var observer = switch (observer_result) {
        .prepared => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!observer.attachment.allowsMutation());
    try std.testing.expectError(
        error.ExternalMode,
        observer.client.call("host.info", null),
    );
    observer.deinit();

    const takeover_result = prepare(allocator, std.testing.io, base, .{
        .runtime_id = runtime_id,
        .intent = .take_over,
    });
    var takeover = switch (takeover_result) {
        .prepared => |value| value,
        .failed => return error.TestUnexpectedResult,
    };
    try std.testing.expect(takeover.attachment.allowsMutation());
    try std.testing.expect(
        takeover.attachment.state.controller_generation >
            controller.attachment.state.controller_generation,
    );
    try std.testing.expectError(
        error.ExternalMode,
        takeover.client.call("host.info", null),
    );
    takeover.deinit();

    var runtime_buf: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&runtime_buf, "{x:0>32}", .{runtime_id});
    var params_buf: [64]u8 = undefined;
    const params = try std.fmt.bufPrint(
        &params_buf,
        "{{\"runtime_id\":\"{s}\"}}",
        .{&runtime_buf},
    );
    const terminated = try owner.call("runtime.terminate", params);
    allocator.free(terminated);
}
