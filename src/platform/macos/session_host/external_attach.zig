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
const client_poison = @import("client_poison.zig");
const compatibility = @import("compatibility.zig");
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const remote_attachment = @import("remote_attachment.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");
const screen_stream = @import("maru").session.screen_stream;
const socket_server = @import("socket_server.zig");
extern "c" fn usleep(usec: c_uint) c_int;

var next_attach_instance_id: std.atomic.Value(u64) = .init(1);

pub const Prepared = struct {
    attach_instance_id: u64,
    client: client_mod.Client,
    attachment: remote_attachment.RemoteAttachment,
    initial_metadata: runtime_metadata_wire.InitialMetadataSeed,

    pub fn deinit(self: *Prepared) void {
        self.initial_metadata.deinit();
        self.attachment.deinit();
        self.client.deinit();
        self.* = undefined;
    }
};

/// **어디서 못 붙었나.** 종료 코드는 "무엇이 막았나"(denied·busy·…)만 말하고 **어느 단계인지**를 안 말한다.
/// 그 둘이 없으면 화면에는 "안 된다" 만 남는다 — `--stream` 은 실제로 stderr 한 줄 없이 exit 4 로 끝났고, 폰에서는
/// 그것이 "화면이 안 온다" 로만 보였다(실측).
///
/// 단계는 **잎이 아니라 이음매**가 붙인다. 잎마다 이유를 실어 나르면 60여 곳이 바뀌고, 그러면 새 잎이 하나
/// 생길 때마다 이름을 또 정해야 한다. 이음매는 `prepareWithTransition` 의 순서 그 자체라 늘 여섯 곳뿐이다.
pub const Stage = enum {
    /// 어느 host 의 어느 runtime 인가를 고르는 중(레지스트리 열거·manifest 대조).
    resolve,
    /// 고른 host 소켓에 붙어 `hello` 를 주고받는 중.
    connect,
    /// 그 runtime 에 observer/controller 로 붙고 첫 화면을 받는 중.
    attach,
    /// 조종을 넘겨받는 중(`--take-over` 만).
    takeover,
    /// 붙은 뒤 그 자리가 아직 유효한지 다시 보는 중(조종 회수 확인).
    publish,
    /// 이 프로세스를 external 모드로 바꾸는 중.
    transition,
};

pub const Failure = struct {
    code: attach_cli.ExitCode,
    stage: Stage,
};

pub const Result = union(enum) {
    prepared: Prepared,
    failed: Failure,
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
        return failed(.internal, .resolve);
    const resolved = attach_product_resolver.resolveProduct(
        allocator,
        base_cache_dir,
        request.runtime_id,
        resolve_phase,
    );
    var pinned = switch (resolved) {
        .selected => |value| value,
        .failed => |code| return failed(code, .resolve),
    };
    defer pinned.deinit();

    const connect_phase = attach_phase_deadline.PhaseDeadline.start(io, .connect_hello) catch
        return failed(.internal, .connect);
    const connected = attach_product_resolver.connectPinned(
        allocator,
        base_cache_dir,
        &pinned,
        request.intent,
        connect_phase,
    );
    var client = switch (connected) {
        .client => |value| value,
        .failed => |code| return failed(code, .connect),
    };
    var client_owned = true;
    defer if (client_owned) client.deinit();

    const requested_mode: remote_attachment.Mode = switch (request.intent) {
        // `--stream` 도 observer 다 — 입력·resize 를 안 보내므로 남의 조종을 안 건드린다(§8).
        // 뷰포트 «선언» 하나는 보내지만(S11-6) 그것은 mutation 을 부르는 것이 아니라 자기 크기를
        // 알리는 것이고, 무엇을 할지는 host 가 정한다.
        .read_only, .take_over, .stream => .observer,
        .default_controller => .controller,
    };
    const attach_phase = attach_phase_deadline.PhaseDeadline.start(io, .attach_snapshot) catch
        return failClient(&client, .internal, .attach);
    const attach_stage = attachSnapshot(
        allocator,
        io,
        &client,
        request.runtime_id,
        requested_mode,
        attach_phase,
    );
    var attached = switch (attach_stage) {
        .attachment => |value| value,
        .failed => |code| return failed(code, .attach),
    };
    var attached_owned = true;
    defer if (attached_owned) attached.deinit();

    if (request.intent == .take_over) {
        const code = performTakeover(allocator, io, &client, &attached.attachment);
        if (code) |taken| return failClient(&client, taken, .takeover);
    }
    if (publishGate(&client, &attached.attachment)) |gated|
        return failClient(&client, gated, .publish);
    transition(&client) catch |err|
        return failClient(&client, transitionExit(err), .transition);
    const attach_instance_id = allocateAttachInstanceId() orelse
        return failClient(&client, .internal, .transition);

    // Seal the same provenance on both halves. `Prepared.attach_instance_id` is the consumable
    // token; the Client copy is the identity adoption evidence cross-checks against.
    client.attach_instance_id = attach_instance_id;
    attached_owned = false;
    client_owned = false;
    return .{ .prepared = .{
        .attach_instance_id = attach_instance_id,
        .client = client,
        .attachment = attached.attachment,
        .initial_metadata = attached.initial_metadata,
    } };
}

fn allocateAttachInstanceId() ?u64 {
    return allocateAttachInstanceIdFrom(&next_attach_instance_id);
}

fn allocateAttachInstanceIdFrom(counter: *std.atomic.Value(u64)) ?u64 {
    var current = counter.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (counter.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
        } else {
            return current;
        }
    }
    return null;
}

test "external attach instance provenance is monotonic and exhaustion never wraps" {
    var counter: std.atomic.Value(u64) = .init(std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(
        std.math.maxInt(u64) - 1,
        allocateAttachInstanceIdFrom(&counter).?,
    );
    try std.testing.expect(allocateAttachInstanceIdFrom(&counter) == null);
    try std.testing.expectEqual(std.math.maxInt(u64), counter.load(.monotonic));
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
    attachment: Attached,
    failed: attach_cli.ExitCode,
};

const Attached = struct {
    attachment: remote_attachment.RemoteAttachment,
    initial_metadata: runtime_metadata_wire.InitialMetadataSeed,

    fn deinit(self: *Attached) void {
        self.initial_metadata.deinit();
        self.attachment.deinit();
        self.* = undefined;
    }
};

fn exactOwnerSchema(comptime Actual: type, comptime Expected: type) bool {
    const actual = std.meta.fields(Actual);
    const expected = std.meta.fields(Expected);
    if (actual.len != expected.len) return false;
    inline for (actual, expected) |a, e| {
        if (!std.mem.eql(u8, a.name, e.name) or a.type != e.type) return false;
    }
    return true;
}

comptime {
    const PreparedSchema = struct {
        attach_instance_id: u64,
        client: client_mod.Client,
        attachment: remote_attachment.RemoteAttachment,
        initial_metadata: runtime_metadata_wire.InitialMetadataSeed,
    };
    const AttachedSchema = struct {
        attachment: remote_attachment.RemoteAttachment,
        initial_metadata: runtime_metadata_wire.InitialMetadataSeed,
    };
    if (!exactOwnerSchema(Prepared, PreparedSchema) or
        !exactOwnerSchema(Attached, AttachedSchema))
        @compileError("CR3a external attach owner schema changed; update SSOT before implementation");
}

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
    const profile = compatibility.profileForMajor(client.wire_major) orelse
        return failAttachStage(client, .unsupported);
    const generation_schema: runtime_metadata_wire.AttachGenerationSchema = switch (profile.attach_schema) {
        .frozen_controller_only => .frozen_controller_only,
        .granted_roles => if (client.attachment_capabilities.peer_attach_generation)
            .granted_with_generation
        else
            .granted_without_generation,
    };
    var decoded = remote_attachment.decodeAttachResponse(
        allocator,
        attach_response,
        runtime_id,
        requested_mode,
        .{
            .generation_schema = generation_schema,
            .metadata_support = client.metadata_support,
        },
    ) catch |err| {
        client.poison(if (err == error.OutOfMemory)
            .local_resource_exhausted
        else
            .peer_contract_violation);
        return failAttachStage(client, decodeAttachExit(err));
    };
    defer decoded.deinit();
    var accepted: remote_attachment.AttachResult = switch (decoded) {
        .wire_error => |code| return failAttachStage(client, attach_cli.remoteExitCode(code)),
        .accepted => |*value| .{
            .state = value.state,
            .controller_busy = value.controller_busy,
            .initial_metadata = value.initial_metadata.take(),
        },
    };
    defer accepted.deinit();

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
    return .{ .attachment = .{
        .attachment = attachment,
        .initial_metadata = accepted.initial_metadata.take(),
    } };
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

fn decodeAttachExit(err: remote_attachment.AttachDecodeError) attach_cli.ExitCode {
    return switch (err) {
        error.OutOfMemory => .internal,
        error.Malformed => .protocol,
        error.ResourceExhausted => .busy,
        error.CapabilityViolation => .protocol,
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

fn failed(code: attach_cli.ExitCode, stage: Stage) Result {
    return .{ .failed = .{ .code = code, .stage = stage } };
}

fn failClient(client: *client_mod.Client, code: attach_cli.ExitCode, stage: Stage) Result {
    // The caller still owns `client` and its defer performs the one-shot CLI connection close.
    // Fatal transport paths have already crossed `Client.poison`; semantic attach/takeover
    // outcomes must not be relabeled as unexpected shared-connection corruption here.
    _ = client;
    return failed(code, stage);
}

fn failAttachStage(client: *client_mod.Client, code: attach_cli.ExitCode) AttachStage {
    // Same ownership rule as `failClient`: this helper classifies a result, not a poison cause.
    // Outer cleanup closes the dedicated CLI connection after attachment cleanup.
    _ = client;
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

test "external attach semantic wire errors do not fabricate a poison reason" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Peer = struct {
        fn run(fd: std.c.fd_t, response: []const u8) void {
            defer _ = std.c.close(fd);
            if (!readMethod(fd, 1, "runtime.attach")) return;
            socket_server.writeAll(fd, response) catch return;
        }
    };
    const cases = .{
        .{ "runtime_not_found", attach_cli.ExitCode.runtime_not_found },
        .{ "unauthorized", attach_cli.ExitCode.denied },
        .{ "resource_exhausted", attach_cli.ExitCode.busy },
    };
    inline for (cases) |case| {
        var fds: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
        );
        var body_buffer: [96]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &body_buffer,
            "{{\"error\":\"{s}\"}}",
            .{case[0]},
        );
        const response = try framing.encodeFrame(
            std.testing.allocator,
            .{ .kind = .response, .request_id = 1 },
            body,
        );
        defer std.testing.allocator.free(response);
        var peer = try std.Thread.spawn(.{}, Peer.run, .{ fds[1], response });
        var client: client_mod.Client = .{
            .allocator = std.testing.allocator,
            .fd = fds[0],
            .host_id = 1,
            .parser = framing.FrameParser.init(std.testing.allocator),
            .attachment_capabilities = .{
                .peer_attach_generation = true,
                .negotiated_controller_transfer = true,
            },
            .metadata_support = .supported,
        };
        defer client.deinit();
        const absolute = try @import("client_deadline.zig").AbsoluteDeadline.after(
            std.testing.io,
            std.time.ns_per_s,
        );
        const stage = attachSnapshot(
            std.testing.allocator,
            std.testing.io,
            &client,
            0xaa,
            .controller,
            attach_phase_deadline.PhaseDeadline.fromAbsolute(.attach_snapshot, absolute),
        );
        peer.join();
        try std.testing.expectEqual(case[1], stage.failed);
        try std.testing.expectEqual(
            @as(?client_poison.ConnectionReason, null),
            client.firstPoisonReason(),
        );
        try std.testing.expect(!client.unusable);
    }
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
    const result = failClient(&client, transitionExit(error.FlagFailed), .transition);
    try std.testing.expectEqual(
        attach_cli.ExitCode.internal,
        switch (result) {
            .failed => |f| f.code,
            .prepared => return error.TestUnexpectedResult,
        },
    );
    // Product `prepare` closes this dedicated CLI client while unwinding its owner defer.
    client.deinit();
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

const SnapshotSuccessPeer = struct {
    request_seen: bool = false,

    fn run(
        self: *SnapshotSuccessPeer,
        fd: std.c.fd_t,
        response: []const u8,
        snapshot: []const u8,
    ) void {
        defer _ = std.c.close(fd);
        var header_bytes: [protocol.header_size]u8 = undefined;
        if (!readExact(fd, &header_bytes)) return;
        const header = protocol.Header.decode(&header_bytes) catch return;
        if (header.kind != .request or header.request_id != 1) return;
        const payload = std.heap.page_allocator.alloc(u8, header.payload_len) catch return;
        defer std.heap.page_allocator.free(payload);
        if (!readExact(fd, payload)) return;
        if (std.mem.indexOf(u8, payload, "\"method\":\"runtime.attach\"") == null) return;
        self.request_seen = true;
        socket_server.writeAll(fd, response) catch return;
        const snapshot_frame = framing.encodeFrame(
            std.heap.page_allocator,
            .{
                .kind = .snapshot_chunk,
                .stream_id = 7,
                .flags = protocol.Flags.end_stream,
            },
            snapshot,
        ) catch return;
        defer std.heap.page_allocator.free(snapshot_frame);
        socket_server.writeAll(fd, snapshot_frame) catch return;
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

test "external attach snapshot owns unsupported unavailable and current metadata seeds" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    defer snapshot.deinit(allocator);
    const meta = try screen_stream.encodeScreenMeta(
        allocator,
        .{ .kind = .screen_meta, .generation = 1 },
        .{ .cols = 1, .rows = 1, .cursor = .{} },
    );
    defer allocator.free(meta);
    try screen_stream.appendRecord(&snapshot, allocator, meta);
    var runs = [_]screen_stream.Run{.{ .grapheme = "x", .width = 1, .count = 1 }};
    const row = try screen_stream.encodeRow(
        allocator,
        .{ .kind = .row, .generation = 1 },
        .{ .row_index = 0, .runs = &runs },
    );
    defer allocator.free(row);
    try screen_stream.appendRecord(&snapshot, allocator, row);

    const cases = [_]struct {
        support: runtime_metadata_wire.MetadataSupport,
        body: []const u8,
        expected: enum { unsupported, unavailable, current },
    }{
        .{
            .support = .unsupported,
            .body = "{\"result\":{\"stream_id\":7,\"controller_generation\":1,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false}}",
            .expected = .unsupported,
        },
        .{
            .support = .supported,
            .body = "{\"result\":{\"stream_id\":7,\"controller_generation\":1,\"granted\":{\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false,\"metadata_revision\":0,\"metadata\":null}}",
            .expected = .unavailable,
        },
        .{
            .support = .supported,
            .body =
            \\{"result":{"stream_id":7,"controller_generation":1,"granted":{"observe":true,"input":true,"resize":true},"controller_busy":false,"metadata_revision":4,"metadata":{"cwd":"\/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":true,"foreground_pgid":7,"processes":[{"pid":7,"name":"z\u0073h"}]}}}
            ,
            .expected = .current,
        },
    };
    for (cases) |case| {
        var fds: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(
            @as(c_int, 0),
            std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
        );
        const response = try framing.encodeFrame(
            allocator,
            .{ .kind = .response, .request_id = 1 },
            case.body,
        );
        defer allocator.free(response);
        var peer_state = SnapshotSuccessPeer{};
        var peer = try std.Thread.spawn(.{}, SnapshotSuccessPeer.run, .{
            &peer_state,
            fds[1],
            response,
            snapshot.items,
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
            .metadata_support = case.support,
        };
        defer client.deinit();
        const absolute = try @import("client_deadline.zig").AbsoluteDeadline.after(
            std.testing.io,
            std.time.ns_per_s,
        );
        var stage = attachSnapshot(
            allocator,
            std.testing.io,
            &client,
            0xaa,
            .controller,
            attach_phase_deadline.PhaseDeadline.fromAbsolute(.attach_snapshot, absolute),
        );
        peer.join();
        try std.testing.expect(peer_state.request_seen);
        switch (stage) {
            .failed => return error.TestUnexpectedResult,
            .attachment => |*attached| {
                defer attached.deinit();
                switch (case.expected) {
                    .unsupported => try std.testing.expectEqual(
                        runtime_metadata_wire.InitialMetadataSeed.unsupported,
                        attached.initial_metadata,
                    ),
                    .unavailable => try std.testing.expectEqual(
                        runtime_metadata_wire.InitialMetadataSeed.unavailable,
                        attached.initial_metadata,
                    ),
                    .current => {
                        try std.testing.expectEqualStrings(
                            "/repo",
                            attached.initial_metadata.current.cwd(),
                        );
                        try std.testing.expectEqualStrings(
                            "zsh",
                            attached.initial_metadata.current.foregroundProcesses()[0].slice(),
                        );
                        const backing = attached.initial_metadata.current.backing orelse
                            return error.TestUnexpectedResult;
                        const backing_start = @intFromPtr(backing.ptr);
                        const response_start = @intFromPtr(response.ptr);
                        try std.testing.expect(
                            backing_start + backing.len <= response_start or
                                response_start + response.len <= backing_start,
                        );
                    },
                }
            },
        }
    }
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
        .metadata_support = .supported,
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

test "external attach maps resource-exhausting metadata to busy and closes before snapshot" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var processes: std.Io.Writer.Allocating = .init(allocator);
    defer processes.deinit();
    for (0..runtime_metadata_wire.max_process_entries + 1) |index| {
        if (index != 0) try processes.writer.writeByte(',');
        try processes.writer.print("{{\"pid\":{d},\"name\":\"p\"}}", .{index});
    }
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"result\":{{\"stream_id\":7,\"controller_generation\":1,\"granted\":{{\"observe\":true,\"input\":true,\"resize\":true}},\"controller_busy\":false,\"metadata_revision\":1,\"metadata\":{{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":1,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":1,\"processes\":[{s}]}}}}}}",
        .{processes.written()},
    );
    defer allocator.free(body);
    const response = try framing.encodeFrame(
        allocator,
        .{ .kind = .response, .request_id = 1 },
        body,
    );
    defer allocator.free(response);
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds),
    );
    socket_server.setNoSigPipe(fds[0]);
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
        .metadata_support = .supported,
    };
    defer client.deinit();
    const absolute = try @import("client_deadline.zig").AbsoluteDeadline.after(
        std.testing.io,
        std.time.ns_per_s,
    );
    const stage = attachSnapshot(
        allocator,
        std.testing.io,
        &client,
        0xaa,
        .controller,
        attach_phase_deadline.PhaseDeadline.fromAbsolute(.attach_snapshot, absolute),
    );
    try std.testing.expectEqual(attach_cli.ExitCode.busy, stage.failed);
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(stage.failed));
    peer.join();
    try std.testing.expect(peer_state.response_sent);
    try std.testing.expect(peer_state.eof_seen);
    try std.testing.expectEqual(@as(usize, 0), peer_state.bytes_after_attach);
    try std.testing.expect(client.unusable);
    try std.testing.expectEqual(@as(std.c.fd_t, -1), client.fd);
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
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
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
    // The fixture namespace is PID-derived, so a crashed prior run followed by PID reuse can
    // leave owner.lock/manifest/socket residue. Starting a daemon on that tree then exits before
    // the connect loop and makes this test order-dependent. Match the resolver fixture's
    // bare-ground contract and make cleanup recursive as well.
    std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
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
        std.Io.Dir.cwd().deleteTree(std.testing.io, base) catch {};
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
    try std.testing.expect(controller.attach_instance_id != 0);
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
        Stage.transition,
        switch (failed_transition) {
            .failed => |f| f.stage,
            .prepared => |value| {
                var unexpected = value;
                unexpected.deinit();
                return error.TestUnexpectedResult;
            },
        },
    );
    try std.testing.expectEqual(
        attach_cli.ExitCode.internal,
        switch (failed_transition) {
            .failed => |f| f.code,
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
    try std.testing.expect(observer.attach_instance_id != 0);
    try std.testing.expect(observer.attach_instance_id != controller.attach_instance_id);
    const observer_instance_id = observer.attach_instance_id;
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
    try std.testing.expect(takeover.attach_instance_id != 0);
    try std.testing.expect(takeover.attach_instance_id != controller.attach_instance_id);
    try std.testing.expect(takeover.attach_instance_id != observer_instance_id);
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
