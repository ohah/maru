//! CR6e-c2 blocking exact-host reconnect worker issuer.
//!
//! c3 owns threads, queues, cancellation wake and joining. This leaf owns one blocking call and
//! the move-by-convention candidate Client until the main owner takes or abandons its completion.

const std = @import("std");
const attach_phase_deadline = @import("attach_phase_deadline.zig");
const client_deadline = @import("client_deadline.zig");
const client_mod = @import("client.zig");
const framing = @import("framing.zig");
const host_connect = @import("host_connect.zig");
const process_identity = @import("process_identity.zig");
const worker_owner = @import("reconnect_worker_owner.zig");

pub const WorkOrder = struct {
    key: worker_owner.Key,
    snapshot: worker_owner.Snapshot,
};

pub const Outcome = worker_owner.Outcome;

const Lifecycle = enum(u8) { pristine, ready, consumed };

pub const Completion = struct {
    self_addr: usize = 0,
    pid: u32 = 0,
    order: WorkOrder = zero_order,
    result: Outcome = .cancelled,
    candidate: ?client_mod.Client = null,
    seal: [32]u8 = [_]u8{0} ** 32,
    lifecycle: Lifecycle = .pristine,

    pub fn outcome(self: *const Completion) !Outcome {
        try self.validate();
        return self.result;
    }

    /// Transfers the sole candidate owner. The returned value follows Client's existing
    /// move-by-convention contract; this completion becomes a consumed tombstone first.
    pub fn takeClient(self: *Completion) !client_mod.Client {
        try self.validate();
        if (self.result != .connected or self.candidate == null) return error.NoCandidate;
        const candidate = self.candidate.?;
        self.candidate = null;
        self.lifecycle = .consumed;
        return candidate;
    }

    pub fn consumeFailure(self: *Completion) !void {
        try self.validate();
        if (self.result == .connected or self.candidate != null) return error.CandidatePresent;
        self.lifecycle = .consumed;
    }

    /// Abandon is the only cleanup path for an untaken successful candidate.
    pub fn abandon(self: *Completion) !void {
        try self.validate();
        if (self.candidate) |*candidate| candidate.deinit();
        self.candidate = null;
        self.lifecycle = .consumed;
    }

    fn validate(self: *const Completion) !void {
        const expected_seal = completionSeal(self);
        if (self.lifecycle != .ready or self.self_addr != @intFromPtr(self) or
            self.pid == 0 or self.pid != process_identity.currentProcessId() or
            !validOrder(self.order) or !std.mem.eql(u8, &self.seal, &expected_seal) or
            ((self.result == .connected) != (self.candidate != null)))
            return error.InvalidCompletion;
    }
};

const zero_order: WorkOrder = .{
    .key = .{ .slot = 0, .generation = 0 },
    .snapshot = .{
        .host_id = 0,
        .pool_membership_generation = 0,
        .connection_generation = 0,
        .incident_app_instance_nonce = 0,
        .incident_sequence = 0,
        .absolute_deadline_ns = 0,
    },
};

const Connector = struct {
    context: *anyopaque,
    connect: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        base_cache_dir: []const u8,
        host_id: u128,
        phase: attach_phase_deadline.PhaseDeadline,
    ) host_connect.Outcome,
};

const product_connector: Connector = .{
    .context = @ptrFromInt(1),
    .connect = productConnect,
};

fn productConnect(
    _: *anyopaque,
    allocator: std.mem.Allocator,
    base_cache_dir: []const u8,
    host_id: u128,
    phase: attach_phase_deadline.PhaseDeadline,
) host_connect.Outcome {
    return host_connect.connectExistingHostUntil(allocator, base_cache_dir, host_id, phase);
}

pub fn executeInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_cache_dir: []const u8,
    order: WorkOrder,
    cancelled: *const std.atomic.Value(u8),
    out: *Completion,
) !void {
    return executeIntoWith(allocator, io, base_cache_dir, order, cancelled, out, product_connector);
}

fn executeIntoWith(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_cache_dir: []const u8,
    order: WorkOrder,
    cancelled: *const std.atomic.Value(u8),
    out: *Completion,
    connector: Connector,
) !void {
    if (!std.meta.eql(out.*, Completion{}) or !validOrder(order) or base_cache_dir.len == 0)
        return error.InvalidWorkOrder;
    if (cancelled.load(.acquire) != 0) return finish(out, order, .cancelled, null);
    const expires_at: i128 = order.snapshot.absolute_deadline_ns;
    const absolute = client_deadline.AbsoluteDeadline.fromAbsolute(io, expires_at) catch
        return finish(out, order, .deadline_exceeded, null);
    const phase = attach_phase_deadline.PhaseDeadline.fromAbsolute(.connect_hello, absolute);
    var connected = connector.connect(
        connector.context,
        allocator,
        base_cache_dir,
        order.snapshot.host_id,
        phase,
    );
    if (cancelled.load(.acquire) != 0) {
        if (connected == .connected) connected.connected.deinit();
        return finish(out, order, .cancelled, null);
    }
    switch (connected) {
        .failed => |reason| return finish(out, order, classifyFailure(reason), null),
        .connected => |candidate| {
            if (candidate.fd < 0 or candidate.host_id != order.snapshot.host_id or
                !candidate.runtime_catchup_barrier_v1 or candidate.connection_profile != .gui)
            {
                var rejected = candidate;
                rejected.deinit();
                return finish(out, order, .retry_later, null);
            }
            return finish(out, order, .connected, candidate);
        },
    }
}

fn finish(out: *Completion, order: WorkOrder, result: Outcome, candidate: ?client_mod.Client) void {
    out.* = .{
        .self_addr = @intFromPtr(out),
        .pid = process_identity.currentProcessId(),
        .order = order,
        .result = result,
        .candidate = candidate,
        .lifecycle = .ready,
    };
    out.seal = completionSeal(out);
}

fn completionSeal(completion: *const Completion) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.reconnect-worker-completion.v1\x00");
    hasher.update(std.mem.asBytes(&completion.self_addr));
    hasher.update(std.mem.asBytes(&completion.pid));
    hasher.update(std.mem.asBytes(&completion.order.key.slot));
    hasher.update(std.mem.asBytes(&completion.order.key.generation));
    hasher.update(std.mem.asBytes(&completion.order.snapshot.host_id));
    hasher.update(std.mem.asBytes(&completion.order.snapshot.pool_membership_generation));
    hasher.update(std.mem.asBytes(&completion.order.snapshot.connection_generation));
    hasher.update(std.mem.asBytes(&completion.order.snapshot.incident_app_instance_nonce));
    hasher.update(std.mem.asBytes(&completion.order.snapshot.incident_sequence));
    hasher.update(std.mem.asBytes(&completion.order.snapshot.absolute_deadline_ns));
    const result_raw: u8 = @intFromEnum(completion.result);
    hasher.update(std.mem.asBytes(&result_raw));
    if (completion.candidate) |*candidate| {
        const digest = candidate.clientProjectionAuthorityDigest();
        hasher.update(&digest);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn classifyFailure(reason: host_connect.FailureReason) Outcome {
    return switch (reason) {
        .host_gone => .host_gone,
        .deadline_exceeded => .deadline_exceeded,
        else => .retry_later,
    };
}

fn validOrder(order: WorkOrder) bool {
    const snapshot = order.snapshot;
    return order.key.generation != 0 and order.key.slot < worker_owner.max_jobs and
        snapshot.host_id != 0 and snapshot.pool_membership_generation != 0 and
        snapshot.connection_generation != 0 and snapshot.incident_app_instance_nonce != 0 and
        snapshot.incident_sequence != 0 and snapshot.absolute_deadline_ns != 0;
}

fn testOrder(io: std.Io, host_id: u128) WorkOrder {
    const now = std.Io.Clock.awake.now(io).nanoseconds;
    return .{
        .key = .{ .slot = 1, .generation = 2 },
        .snapshot = .{
            .host_id = host_id,
            .pool_membership_generation = 3,
            .connection_generation = 4,
            .incident_app_instance_nonce = (@as(u128, 1) << 96) | 5,
            .incident_sequence = 6,
            .absolute_deadline_ns = @intCast(now + 5 * std.time.ns_per_s),
        },
    };
}

const TestConnector = struct {
    calls: usize = 0,
    result: host_connect.FailureReason = .transient_timeout,
    connected: bool = false,
    wrong_host: bool = false,
    cancel_on_return: ?*std.atomic.Value(u8) = null,
    observed_host_id: u128 = 0,
    observed_deadline_ns: i128 = 0,
    client_fd: std.c.fd_t = -1,
    peer_fd: std.c.fd_t = -1,

    fn run(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        host_id: u128,
        phase: attach_phase_deadline.PhaseDeadline,
    ) host_connect.Outcome {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.observed_host_id = host_id;
        self.observed_deadline_ns = phase.absolute.expires_at_ns;
        if (self.cancel_on_return) |cancel| cancel.store(1, .release);
        if (!self.connected) return .{ .failed = self.result };
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0)
            return .{ .failed = .resource_exhausted };
        self.client_fd = fds[0];
        self.peer_fd = fds[1];
        return .{ .connected = .{
            .allocator = allocator,
            .fd = fds[0],
            .host_id = if (self.wrong_host) host_id + 1 else host_id,
            .runtime_catchup_barrier_v1 = true,
            .connection_profile = .gui,
            .parser = framing.FrameParser.init(allocator),
        } };
    }

    fn connector(self: *@This()) Connector {
        return .{ .context = self, .connect = run };
    }

    fn closePeer(self: *@This()) void {
        if (self.peer_fd >= 0) {
            _ = std.c.close(self.peer_fd);
            self.peer_fd = -1;
        }
    }

    fn expectClientClosed(self: *const @This()) !void {
        try std.testing.expect(self.client_fd >= 0);
        try std.testing.expect(std.c.fcntl(self.client_fd, std.c.F.GETFD, @as(c_int, 0)) < 0);
    }
};

test "CR6e-c2 issuer preserves exact host and absolute deadline then moves candidate once" {
    const io = std.testing.io;
    const order = testOrder(io, 101);
    var fixture = TestConnector{ .connected = true };
    defer fixture.closePeer();
    var cancelled = std.atomic.Value(u8).init(0);
    var completion: Completion = .{};
    try executeIntoWith(std.testing.allocator, io, "/tmp/cache", order, &cancelled, &completion, fixture.connector());
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(order.snapshot.host_id, fixture.observed_host_id);
    try std.testing.expectEqual(@as(i128, order.snapshot.absolute_deadline_ns), fixture.observed_deadline_ns);
    try std.testing.expectEqual(Outcome.connected, try completion.outcome());
    var copied = completion;
    try std.testing.expectError(error.InvalidCompletion, copied.takeClient());
    const canonical_sequence = completion.order.snapshot.incident_sequence;
    completion.order.snapshot.incident_sequence += 1;
    try std.testing.expectError(error.InvalidCompletion, completion.takeClient());
    completion.order.snapshot.incident_sequence = canonical_sequence;
    var client = try completion.takeClient();
    try std.testing.expectEqual(order.snapshot.host_id, client.host_id);
    client.deinit();
    try fixture.expectClientClosed();
    try std.testing.expectError(error.InvalidCompletion, completion.takeClient());
}

test "CR6e-c2 issuer maps host gone deadline and transient failures without candidates" {
    const io = std.testing.io;
    inline for (.{
        .{ host_connect.FailureReason.host_gone, Outcome.host_gone },
        .{ host_connect.FailureReason.deadline_exceeded, Outcome.deadline_exceeded },
        .{ host_connect.FailureReason.handshake_failed, Outcome.retry_later },
    }) |row| {
        var fixture = TestConnector{ .result = row[0] };
        var cancelled = std.atomic.Value(u8).init(0);
        var completion: Completion = .{};
        try executeIntoWith(std.testing.allocator, io, "/tmp/cache", testOrder(io, 102), &cancelled, &completion, fixture.connector());
        try std.testing.expectEqual(row[1], try completion.outcome());
        try completion.consumeFailure();
    }
}

test "CR6e-c2 issuer cancellation before connect performs zero work" {
    const io = std.testing.io;
    var fixture = TestConnector{};
    var cancelled = std.atomic.Value(u8).init(1);
    var completion: Completion = .{};
    try executeIntoWith(std.testing.allocator, io, "/tmp/cache", testOrder(io, 103), &cancelled, &completion, fixture.connector());
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(Outcome.cancelled, try completion.outcome());
    try completion.consumeFailure();
}

test "CR6e-c2 issuer cancellation after connect closes candidate" {
    const io = std.testing.io;
    var cancelled = std.atomic.Value(u8).init(0);
    var fixture = TestConnector{ .connected = true, .cancel_on_return = &cancelled };
    defer fixture.closePeer();
    var completion: Completion = .{};
    try executeIntoWith(std.testing.allocator, io, "/tmp/cache", testOrder(io, 104), &cancelled, &completion, fixture.connector());
    try std.testing.expectEqual(Outcome.cancelled, try completion.outcome());
    try fixture.expectClientClosed();
    try completion.consumeFailure();
}

test "CR6e-c2 issuer abandon closes an untaken candidate exact once" {
    const io = std.testing.io;
    var fixture = TestConnector{ .connected = true };
    defer fixture.closePeer();
    var cancelled = std.atomic.Value(u8).init(0);
    var completion: Completion = .{};
    try executeIntoWith(std.testing.allocator, io, "/tmp/cache", testOrder(io, 105), &cancelled, &completion, fixture.connector());
    try completion.abandon();
    try fixture.expectClientClosed();
    try std.testing.expectError(error.InvalidCompletion, completion.abandon());
}

test "CR6e-c2 issuer rejects mismatched successful candidate and closes it" {
    const io = std.testing.io;
    var fixture = TestConnector{ .connected = true, .wrong_host = true };
    defer fixture.closePeer();
    var cancelled = std.atomic.Value(u8).init(0);
    var completion: Completion = .{};
    try executeIntoWith(std.testing.allocator, io, "/tmp/cache", testOrder(io, 106), &cancelled, &completion, fixture.connector());
    try std.testing.expectEqual(Outcome.retry_later, try completion.outcome());
    try fixture.expectClientClosed();
    try completion.consumeFailure();
}

test "CR6e-c2 issuer expired and invalid work orders never call connector" {
    const io = std.testing.io;
    var fixture = TestConnector{};
    var cancelled = std.atomic.Value(u8).init(0);
    var expired = testOrder(io, 107);
    expired.snapshot.absolute_deadline_ns = 1;
    var completion: Completion = .{};
    try executeIntoWith(std.testing.allocator, io, "/tmp/cache", expired, &cancelled, &completion, fixture.connector());
    try std.testing.expectEqual(Outcome.deadline_exceeded, try completion.outcome());
    try completion.consumeFailure();
    var invalid = testOrder(io, 108);
    invalid.key.generation = 0;
    var invalid_out: Completion = .{};
    try std.testing.expectError(error.InvalidWorkOrder, executeIntoWith(
        std.testing.allocator,
        io,
        "/tmp/cache",
        invalid,
        &cancelled,
        &invalid_out,
        fixture.connector(),
    ));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
