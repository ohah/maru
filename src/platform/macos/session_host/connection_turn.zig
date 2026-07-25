//! Nonblocking, connection-local readiness turn adapter for the session-host reactor.
//!
//! The daemon poll owner decides which fd is ready. This module owns one fd, parser, protocol
//! `Connection`, and the outbound bytes charged to its `connection_slot.Slot`; it never polls or
//! waits. T0b2 only has to admit/remove these stable heap clients and schedule one turn at a time.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const framing = @import("framing.zig");
const protocol = @import("protocol.zig");
const registry = @import("registry.zig");
const server = @import("server.zig");
const slot_mod = @import("connection_slot.zig");
const subscription_identity = @import("subscription_identity.zig");
const upgrade = @import("upgrade_coordinator.zig");
const upgrade_wire = @import("upgrade_wire.zig");

pub const CloseReason = enum {
    eof,
    socket_error,
    protocol_error,
    resource_exhausted,
    admission_closed,
    peer_requested,
    reply_flushed,
    partial_timeout,
    upgrade_completed,
    upgrade_failed,
};

pub const State = union(enum) {
    open,
    closing: CloseReason,
};

pub const ArmedUpgrade = struct {
    attempt_id: u128,
    /// `upgrade_attempt.freezePreclosed` is mandatory for this marker.
    gate_preclosed: bool = true,
};

pub const inbound_resident_cap: usize =
    protocol.header_size + protocol.max_binary_chunk;
pub const handshake_deadline_ns: u64 = 10 * std.time.ns_per_s;
pub const unattached_idle_deadline_ns: u64 = 30 * std.time.ns_per_s;

pub const Options = struct {
    runtime_ops: ?server.RuntimeOps = null,
    upgrade_ops: ?upgrade_wire.Ops = null,
    admission_gate: ?*upgrade.AdmissionGate = null,
    host_status: server.HostStatus = .{},
    live_host_status: ?*const server.HostStatus = null,
    now_ns: u64 = 0,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    reactor: *slot_mod.ReactorCore,
    admission: slot_mod.ReactorCore.Admission,
    parser: framing.FrameParser,
    connection: server.Connection,
    trackers: std.AutoHashMapUnmanaged(u64, slot_mod.ScreenTrackerKey) = .empty,
    state: State = .open,
    close_after_flush: ?CloseReason = null,
    pending_upgrade: ?u128 = null,
    upgrade_gate_closed: bool = false,
    upgrade_ops: ?upgrade_wire.Ops,
    admission_gate: ?*upgrade.AdmissionGate,
    armed_upgrade: ?u128 = null,
    destroyed: bool = false,
    created_ns: u64,
    last_activity_ns: u64,
    sync_fail_once: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        fd: c.fd_t,
        reactor: *slot_mod.ReactorCore,
        host_id: u128,
        registry_ptr: *registry.TerminalRuntimeRegistry,
        subscriptions: *subscription_identity.Table,
        options: Options,
    ) error{ OutOfMemory, SocketSetupFailed, Full, Exhausted }!*Client {
        errdefer _ = c.close(fd);
        try configureOwnedSocket(fd);
        const admission = reactor.admit() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Full => error.Full,
            error.Exhausted => error.Exhausted,
        };
        errdefer reactor.closeConnection(admission) catch unreachable;
        const self = allocator.create(Client) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .reactor = reactor,
            .admission = admission,
            .parser = framing.FrameParser.init(allocator),
            .connection = server.Connection.initProduct(
                allocator,
                host_id,
                registry_ptr,
                admission.key,
                subscriptions,
            ),
            .upgrade_ops = options.upgrade_ops,
            .admission_gate = options.admission_gate,
            .created_ns = options.now_ns,
            .last_activity_ns = options.now_ns,
        };
        self.connection.runtime_ops = options.runtime_ops;
        self.connection.upgrade_ops = options.upgrade_ops;
        self.connection.host_status = options.host_status;
        self.connection.live_host_status = options.live_host_status;
        return self;
    }

    /// Canonical removal path. The protocol connection revokes subscriptions before the reactor
    /// slot releases queued accounting; fd ownership ends exactly once.
    pub fn destroy(self: *Client) void {
        std.debug.assert(!self.destroyed);
        std.debug.assert(self.armed_upgrade == null);
        self.destroyed = true;
        if (self.pending_upgrade) |attempt_id| {
            if (self.upgrade_ops) |ops| ops.cancel_unaccepted(ops.ctx, attempt_id);
            self.pending_upgrade = null;
        }
        if (self.upgrade_gate_closed) {
            self.admission_gate.?.cancelClose();
            self.upgrade_gate_closed = false;
        }
        _ = c.close(self.fd);
        self.fd = -1;
        self.connection.deinit();
        self.trackers.deinit(self.allocator);
        self.parser.deinit();
        self.reactor.closeConnection(self.admission) catch unreachable;
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn wantsWrite(self: *Client) bool {
        const slot = self.reactor.get(self.admission) catch return false;
        return slot.firstPending() != null;
    }

    pub fn hasBufferedReadWork(self: *const Client) bool {
        return self.parser.bufferState() == .complete_or_error;
    }

    pub fn isClosing(self: *const Client) bool {
        return switch (self.state) {
            .open => false,
            .closing => true,
        };
    }

    /// T0b2 owner calls this before canonical destroy, but publishes the host-global completed
    /// marker only after destroy removed fd/subscriptions/slot. A second take cannot re-arm.
    pub fn takeArmedUpgrade(self: *Client) ?ArmedUpgrade {
        const attempt = self.armed_upgrade;
        self.armed_upgrade = null;
        return if (attempt) |attempt_id| .{ .attempt_id = attempt_id } else null;
    }

    /// One nonblocking readable turn. At most 1 MiB and 64 complete frames are admitted.
    pub fn readReady(self: *Client, now_ns: u64) void {
        if (self.isClosing() or self.close_after_flush != null) return;
        var budget: slot_mod.TurnBudget = .{};
        var buf: [64 * 1024]u8 = undefined;
        var interruptions: u8 = 0;

        // Complete buffered frames always drain before another socket read. This bounds inbound
        // resident growth when a previous turn stopped at frame 64.
        if (self.drainBuffered(&budget, now_ns, false)) return;
        while (budget.read_bytes < slot_mod.turn_bytes and
            budget.read_frames < slot_mod.turn_frames)
        {
            if (self.parser.bufferedBytes() >= inbound_resident_cap)
                return self.beginClose(.resource_exhausted);
            const turn_remaining = slot_mod.turn_bytes - budget.read_bytes;
            const resident_remaining = inbound_resident_cap - self.parser.bufferedBytes();
            const rc = c.recv(
                self.fd,
                &buf,
                @min(buf.len, @min(turn_remaining, resident_remaining)),
                posix.MSG.DONTWAIT,
            );
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .INTR => {
                        interruptions += 1;
                        if (interruptions == 8) return;
                        continue;
                    },
                    .AGAIN => return,
                    else => return self.beginClose(.socket_error),
                }
            }
            if (rc == 0) return self.beginClose(.eof);
            const bytes = buf[0..@intCast(rc)];
            self.last_activity_ns = now_ns;
            if (!budget.allowRead(bytes.len, 0)) return;
            self.parser.pushBounded(bytes, inbound_resident_cap) catch
                return self.beginClose(.resource_exhausted);
            if (self.drainBuffered(&budget, now_ns, true)) return;
        }
    }

    fn drainBuffered(
        self: *Client,
        budget: *slot_mod.TurnBudget,
        now_ns: u64,
        read_progressed: bool,
    ) bool {
        const slot = self.reactor.get(self.admission) catch {
            self.beginClose(.socket_error);
            return true;
        };
        while (budget.read_frames < slot_mod.turn_frames) {
            const outcome = self.parser.nextOutcome() catch |err| {
                self.beginClose(switch (err) {
                    error.OutOfMemory => .resource_exhausted,
                    else => .protocol_error,
                });
                return true;
            };
            switch (outcome) {
                .incomplete => break,
                .skipped => {
                    slot.clearPartial(.read);
                    _ = budget.allowRead(0, 1);
                },
                .frame => |frame| {
                    slot.clearPartial(.read);
                    _ = budget.allowRead(0, 1);
                    defer frame.deinit(self.allocator);
                    self.dispatch(frame) catch {
                        self.beginClose(.resource_exhausted);
                        return true;
                    };
                },
            }
            if (self.close_after_flush != null or self.isClosing()) return true;
        }
        switch (self.parser.bufferState()) {
            .incomplete => slot.notePartial(.read, now_ns, read_progressed),
            .empty, .complete_or_error => slot.clearPartial(.read),
        }
        return budget.read_frames == slot_mod.turn_frames;
    }

    /// One nonblocking writable turn. Queue offsets and global accounting advance only by bytes
    /// accepted by the kernel.
    pub fn writeReady(self: *Client, now_ns: u64) void {
        if (self.isClosing()) return;
        var budget: slot_mod.TurnBudget = .{};
        var interruptions: u8 = 0;
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        while (slot.firstPending()) |pending| {
            const allowance = slot_mod.turn_bytes - budget.write_bytes;
            if (allowance == 0 or budget.write_frames == slot_mod.turn_frames) return;
            const bytes = pending.bytes[0..@min(pending.bytes.len, allowance)];
            const rc = c.send(self.fd, bytes.ptr, bytes.len, posix.MSG.DONTWAIT);
            if (rc < 0) {
                switch (posix.errno(rc)) {
                    .INTR => {
                        interruptions += 1;
                        if (interruptions == 8) return;
                        continue;
                    },
                    .AGAIN => {
                        slot.notePartial(.write, now_ns, false);
                        return;
                    },
                    else => return self.failPendingUpgrade(.socket_error),
                }
            }
            if (rc == 0) return self.failPendingUpgrade(.socket_error);
            const written: usize = @intCast(rc);
            self.last_activity_ns = now_ns;
            const completed_chunk = written == pending.bytes.len;
            slot.consumeWritten(written) catch return self.failPendingUpgrade(.socket_error);
            _ = budget.allowWrite(written, @intFromBool(completed_chunk));
            if (!completed_chunk) {
                slot.notePartial(.write, now_ns, true);
                return;
            }
            // A new queue head gets its own absolute deadline. If the turn cap leaves it queued,
            // its progress clock starts only on its first write/EAGAIN attempt.
            slot.clearPartial(.write);
        }
        slot.clearPartial(.write);
        if (self.pending_upgrade != null) return self.finalizePendingUpgrade();
        if (self.close_after_flush) |reason| {
            self.close_after_flush = null;
            self.beginClose(reason);
        }
    }

    /// Deadline/lifecycle tick; screen updates are queued and therefore cannot block another fd.
    pub fn tick(self: *Client, now_ns: u64) void {
        if (self.isClosing()) return;
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        if (self.pending_upgrade != null and !self.wantsWrite()) {
            self.finalizePendingUpgrade();
            return;
        }
        if (!self.connection.handshakeComplete() and
            elapsedAtLeast(self.created_ns, now_ns, handshake_deadline_ns))
            return self.beginClose(.partial_timeout);
        if (self.connection.handshakeComplete() and
            self.connection.attachmentCount() == 0 and
            !self.wantsWrite() and
            elapsedAtLeast(self.last_activity_ns, now_ns, unattached_idle_deadline_ns))
            return self.beginClose(.partial_timeout);
        if (slot.partialExpired(.read, now_ns) or slot.partialExpired(.write, now_ns))
            return self.failPendingUpgrade(.partial_timeout);
        if (self.close_after_flush != null) return;
        var lease = if (self.admission_gate) |gate| gate.tryEnter() orelse return else null;
        defer if (lease) |*held| held.release();
        slot.beginDispatch() catch return self.beginClose(.resource_exhausted);
        defer slot.endDispatch() catch unreachable;
        const maybe_frames = self.connection.collectDeltas() catch {
            self.beginClose(.resource_exhausted);
            return;
        };
        if (maybe_frames) |frames| {
            defer self.allocator.free(frames);
            var adopted: usize = 0;
            for (frames) |bytes| {
                self.adoptScreen(bytes) catch {
                    for (frames[adopted + 1 ..]) |remaining|
                        self.allocator.free(remaining);
                    self.beginClose(.resource_exhausted);
                    return;
                };
                adopted += 1;
            }
        }
    }

    fn dispatch(self: *Client, frame: framing.Frame) error{OutOfMemory}!void {
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        var lease = if (self.admission_gate) |gate| gate.tryEnter() orelse {
            self.beginClose(.admission_closed);
            return;
        } else null;
        defer if (lease) |*held| held.release();
        slot.beginDispatch() catch return self.beginClose(.resource_exhausted);
        defer slot.endDispatch() catch unreachable;

        const action = try self.connection.handleFrame(frame);
        switch (action) {
            .reply => |bytes| {
                try self.adoptControl(bytes);
                try self.syncTrackers();
            },
            .reply_and_close => |bytes| {
                try self.adoptControl(bytes);
                try self.syncTrackers();
                self.close_after_flush = .reply_flushed;
            },
            .upgrade_accepted => |accepted| {
                const ops = self.upgrade_ops orelse {
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                };
                const gate = self.admission_gate orelse {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                };
                if (!gate.close()) {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                }
                self.upgrade_gate_closed = true;
                self.adoptControl(accepted.bytes) catch {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    gate.cancelClose();
                    self.upgrade_gate_closed = false;
                    return error.OutOfMemory;
                };
                self.pending_upgrade = accepted.attempt_id;
                self.close_after_flush = .upgrade_completed;
            },
            .close => self.beginClose(.peer_requested),
            .none => try self.syncTrackers(),
            .frames => |frames| {
                try self.adoptFrameBatch(frames);
            },
        }
    }

    fn adoptFrameBatch(self: *Client, frames: [][]u8) error{OutOfMemory}!void {
        defer self.allocator.free(frames);
        if (frames.len == 0) return;
        var adopted: usize = 0;
        errdefer for (frames[adopted..]) |bytes| self.allocator.free(bytes);
        try self.syncTrackers();
        adopted = 1;
        try self.adoptControl(frames[0]);
        for (frames[1..]) |bytes| {
            adopted += 1;
            try self.adoptScreen(bytes);
        }
    }

    fn syncTrackers(self: *Client) error{OutOfMemory}!void {
        if (self.sync_fail_once) {
            self.sync_fail_once = false;
            return error.OutOfMemory;
        }
        const slot = self.reactor.get(self.admission) catch
            return self.beginClose(.socket_error);
        const streams = try self.connection.localStreams(self.allocator);
        defer self.allocator.free(streams);
        var removed: [slot_mod.max_screen_trackers_per_slot]u64 = undefined;
        var removed_len: usize = 0;
        var it = self.trackers.keyIterator();
        while (it.next()) |tracked| {
            var live = false;
            for (streams) |stream| {
                if (stream == tracked.*) {
                    live = true;
                    break;
                }
            }
            if (!live) {
                removed[removed_len] = tracked.*;
                removed_len += 1;
            }
        }
        for (removed[0..removed_len]) |stream| {
            const tracker = self.trackers.fetchRemove(stream).?.value;
            slot.purgeAndDestroyScreenTracker(tracker) catch
                return self.beginClose(.socket_error);
            slot.detachStream() catch return self.beginClose(.socket_error);
        }
        for (streams) |stream| {
            if (self.trackers.contains(stream)) continue;
            const tracker = slot.createScreenTracker() catch return error.OutOfMemory;
            errdefer slot.destroyScreenTracker(tracker) catch unreachable;
            self.trackers.put(self.allocator, stream, tracker) catch
                return error.OutOfMemory;
            slot.attachStream() catch return self.beginClose(.resource_exhausted);
        }
    }

    fn adoptControl(self: *Client, bytes: []u8) error{OutOfMemory}!void {
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        slot.enqueueOwnedControl(bytes) catch {
            self.allocator.free(bytes);
            return error.OutOfMemory;
        };
    }

    fn adoptScreen(self: *Client, bytes: []u8) error{OutOfMemory}!void {
        const class = server.classifyOutbound(bytes) catch {
            self.allocator.free(bytes);
            return error.OutOfMemory;
        };
        const stream = switch (class) {
            .control => return self.adoptControl(bytes),
            .screen => |stream| stream,
        };
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        const tracker = self.trackers.get(stream) orelse {
            self.allocator.free(bytes);
            return error.OutOfMemory;
        };
        slot.enqueueOwnedScreen(tracker, bytes) catch {
            self.allocator.free(bytes);
            return error.OutOfMemory;
        };
    }

    fn failPendingUpgrade(self: *Client, reason: CloseReason) void {
        if (self.pending_upgrade) |attempt_id| {
            if (self.upgrade_ops) |ops| ops.cancel_unaccepted(ops.ctx, attempt_id);
            self.pending_upgrade = null;
        }
        if (self.upgrade_gate_closed) {
            self.admission_gate.?.cancelClose();
            self.upgrade_gate_closed = false;
        }
        self.beginClose(reason);
    }

    fn finalizePendingUpgrade(self: *Client) void {
        const attempt_id = self.pending_upgrade orelse return;
        const gate = self.admission_gate orelse
            return self.failPendingUpgrade(.upgrade_failed);
        // Arm records reply-flush linearization only. The typed preclosed coordinator owns the
        // bounded wait for pre-close leases and reader quiesce.
        _ = gate;
        const ops = self.upgrade_ops orelse
            return self.failPendingUpgrade(.upgrade_failed);
        if (ops.arm_accepted(ops.ctx, attempt_id) != .armed)
            return self.failPendingUpgrade(.upgrade_failed);
        self.pending_upgrade = null;
        self.upgrade_gate_closed = false;
        self.armed_upgrade = attempt_id;
        self.beginClose(.upgrade_completed);
    }

    fn beginClose(self: *Client, reason: CloseReason) void {
        if (!self.isClosing()) self.state = .{ .closing = reason };
    }
};

fn elapsedAtLeast(start_ns: u64, now_ns: u64, duration_ns: u64) bool {
    return now_ns >= start_ns and now_ns - start_ns >= duration_ns;
}

pub fn configureOwnedSocket(fd: c.fd_t) error{SocketSetupFailed}!void {
    const descriptor_flags = c.fcntl(fd, c.F.GETFD, @as(c_int, 0));
    if (descriptor_flags < 0 or
        c.fcntl(fd, c.F.SETFD, descriptor_flags | c.FD_CLOEXEC) < 0)
        return error.SocketSetupFailed;
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    const nonblocking: c_int = @bitCast(posix.O{ .NONBLOCK = true });
    if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nonblocking) < 0)
        return error.SocketSetupFailed;
    const one: c_int = 1;
    if (c.setsockopt(
        fd,
        posix.SOL.SOCKET,
        posix.SO.NOSIGPIPE,
        @ptrCast(&one),
        @sizeOf(c_int),
    ) != 0) return error.SocketSetupFailed;
}

const TestUpgradeOwner = struct {
    staged: usize = 0,
    canceled: usize = 0,
    armed: usize = 0,
    attempt_id: u128 = 0,

    fn stage(ctx: *anyopaque, request: upgrade_wire.PrepareRequest) upgrade_wire.PrepareDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.staged += 1;
        self.attempt_id = request.attempt_id;
        return .accepted;
    }
    fn cancel(ctx: *anyopaque, attempt_id: u128) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        std.debug.assert(self.attempt_id == attempt_id);
        self.canceled += 1;
    }
    fn arm(ctx: *anyopaque, attempt_id: u128) upgrade_wire.ArmDecision {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.attempt_id != attempt_id) return .conflict;
        self.armed += 1;
        return .armed;
    }
    fn status(_: *anyopaque, _: u128) ?upgrade_wire.AttemptReport {
        return .{ .status = .pending };
    }
    fn ops(self: *@This()) upgrade_wire.Ops {
        return .{
            .ctx = self,
            .stage_pending = stage,
            .cancel_unaccepted = cancel,
            .arm_accepted = arm,
            .status = status,
        };
    }
};

const test_hello =
    "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[],\"screen_stream_version\":2}";
const test_upgrade_request =
    \\{"method":"host.upgrade.prepare","params":{"attempt_id":"0000000000000000000000000000aabb","target_path":"/Applications/Maru.app/Contents/MacOS/maru","target_build_id":"sha256:build","target_sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","handoff_reader_min":1,"handoff_reader_max":1}}
;

fn sendTestFrame(fd: c.fd_t, kind: protocol.Kind, request_id: u64, payload: []const u8) !void {
    const wire = try framing.encodeFrame(std.testing.allocator, .{
        .kind = kind,
        .request_id = request_id,
    }, payload);
    defer std.testing.allocator.free(wire);
    var offset: usize = 0;
    while (offset < wire.len) {
        const rc = c.send(fd, wire.ptr + offset, wire.len - offset, 0);
        if (rc <= 0) return error.TestUnexpectedResult;
        offset += @intCast(rc);
    }
}

fn drainNonblocking(fd: c.fd_t) usize {
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc <= 0) return total;
        total += @intCast(rc);
    }
}

test "readiness client socketpair yields on partial input and closes canonically on EOF" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);

    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        1,
        &registry_value,
        &subscriptions,
        .{},
    );
    const stale_admission = client.admission;
    const closed_fd = client.fd;

    const hello = try framing.encodeFrame(testing.allocator, .{ .kind = .hello }, "{\"protocol_min\":2,\"protocol_max\":2,\"client\":\"gui\",\"screen_stream_version\":2}");
    defer testing.allocator.free(hello);
    _ = c.write(fds[1], hello.ptr, 7);
    client.readReady(1);
    try testing.expect(!client.isClosing());
    try testing.expect(!client.wantsWrite());
    _ = c.write(fds[1], hello.ptr + 7, hello.len - 7);
    client.readReady(2);
    try testing.expect(client.wantsWrite());
    client.writeReady(3);
    try testing.expect(!client.wantsWrite());

    _ = c.close(fds[1]);
    fds[1] = -1;
    client.readReady(4);
    try testing.expect(client.isClosing());
    client.destroy();
    try testing.expectEqual(@as(usize, 0), reactor.activeCount());
    try testing.expectEqual(@as(usize, 0), subscriptions.count());
    try testing.expectError(error.Stale, reactor.get(stale_admission));
    try testing.expect(c.fcntl(closed_fd, c.F.GETFD, @as(c_int, 0)) < 0);
}

test "readiness client charges skipped optional frame 65 to the next turn before reading more" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        2,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();

    const optional = (protocol.Header{
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    const hello = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .hello },
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[],\"screen_stream_version\":2}",
    );
    defer testing.allocator.free(hello);
    const wire = try testing.allocator.alloc(u8, optional.len * 64 + hello.len);
    defer testing.allocator.free(wire);
    for (0..64) |index|
        @memcpy(wire[index * optional.len ..][0..optional.len], &optional);
    @memcpy(wire[optional.len * 64 ..], hello);
    try testing.expectEqual(@as(isize, @intCast(wire.len)), c.send(
        fds[1],
        wire.ptr,
        wire.len,
        posix.MSG.DONTWAIT,
    ));

    client.readReady(1);
    try testing.expect(!client.wantsWrite());
    try testing.expect(client.parser.bufferedBytes() >= hello.len);
    try testing.expect(client.hasBufferedReadWork());
    const slot = try reactor.get(client.admission);
    try testing.expect(!slot.partialExpired(.read, 1 + slot_mod.partial_absolute_deadline_ns));
    client.readReady(2);
    try testing.expect(client.wantsWrite());
}

test "upgrade reply arms only after EAGAIN tail is fully written and marker is taken once" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var owner: TestUpgradeOwner = .{};
    var gate = upgrade.AdmissionGate.init(testing.io);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        3,
        &registry_value,
        &subscriptions,
        .{
            .upgrade_ops = owner.ops(),
            .admission_gate = &gate,
            .host_status = .{ .manifest_capable = true, .upgrade_capable = true },
        },
    );
    defer client.destroy();

    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    client.writeReady(2);
    try testing.expect(drainNonblocking(fds[1]) != 0);

    var filler: [64 * 1024]u8 = [_]u8{0xA5} ** (64 * 1024);
    while (true) {
        const rc = c.send(client.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    try sendTestFrame(fds[1], .request, 2, test_upgrade_request);
    client.readReady(3);
    try testing.expectEqual(@as(usize, 1), owner.staged);
    client.writeReady(4);
    try testing.expectEqual(@as(usize, 0), owner.armed);
    try testing.expect(client.takeArmedUpgrade() == null);

    try testing.expect(drainNonblocking(fds[1]) != 0);
    client.writeReady(5);
    try testing.expectEqual(@as(usize, 1), owner.armed);
    const armed = client.takeArmedUpgrade().?;
    try testing.expectEqual(@as(u128, 0xAABB), armed.attempt_id);
    try testing.expect(armed.gate_preclosed);
    try testing.expect(client.takeArmedUpgrade() == null);
    try testing.expect(client.isClosing());
    try testing.expectEqual(@as(usize, 0), owner.canceled);
    try testing.expect(!gate.snapshot().open);
}

test "upgrade write after peer close cancels once without SIGPIPE" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var owner: TestUpgradeOwner = .{};
    var gate = upgrade.AdmissionGate.init(testing.io);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        4,
        &registry_value,
        &subscriptions,
        .{
            .upgrade_ops = owner.ops(),
            .admission_gate = &gate,
            .host_status = .{ .manifest_capable = true, .upgrade_capable = true },
        },
    );

    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try sendTestFrame(fds[1], .request, 2, test_upgrade_request);
    client.readReady(3);
    _ = c.close(fds[1]);
    fds[1] = -1;
    client.writeReady(4);
    try testing.expect(client.isClosing());
    try testing.expectEqual(@as(usize, 1), owner.canceled);
    try testing.expectEqual(@as(usize, 0), owner.armed);
    try testing.expect(gate.snapshot().open);
    client.destroy();
}

test "silent pre-hello client has an exact bounded handshake deadline" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        5,
        &registry_value,
        &subscriptions,
        .{ .now_ns = 100 },
    );
    defer client.destroy();
    client.tick(100 + handshake_deadline_ns - 1);
    try testing.expect(!client.isClosing());
    client.tick(100 + handshake_deadline_ns);
    try testing.expect(client.isClosing());
}

test "frame batch sync failure frees every still-owned inner frame" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        6,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const frames = try testing.allocator.alloc([]u8, 3);
    for (frames, 0..) |*frame, index|
        frame.* = try testing.allocator.dupe(u8, if (index == 0) "a" else "b");
    client.sync_fail_once = true;
    try testing.expectError(error.OutOfMemory, client.adoptFrameBatch(frames));
}

test "completed chunk gives the next queued frame a fresh absolute write deadline" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        7,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const slot = try reactor.get(client.admission);
    for (0..65) |_| try slot.enqueueControl("x");

    const filler: [64 * 1024]u8 = [_]u8{0x5A} ** (64 * 1024);
    while (true) {
        const rc = c.send(client.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    client.writeReady(0);
    try testing.expect(slot.partialExpired(.write, slot_mod.partial_deadline_ns));
    _ = drainNonblocking(fds[1]);
    client.writeReady(9 * std.time.ns_per_s);
    try testing.expectEqual(@as(usize, 1), slot.chunk_len);
    try testing.expect(!slot.partialExpired(.write, 10 * std.time.ns_per_s));
    try testing.expect(!slot.partialExpired(.write, slot_mod.partial_absolute_deadline_ns));
}

test "socketpair attach creates tracker and detach purges only unsent screen frames" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        8,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    try testing.expectEqual(@as(usize, 1), client.trackers.count());
    try testing.expectEqual(@as(usize, 1), slot.attached_streams);
    try testing.expectEqual(slot_mod.QueueClass.control, slot.firstPending().?.class);

    const attach_batch = try testing.allocator.alloc([]u8, 2);
    attach_batch[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .response, .request_id = 2 },
        "{\"result\":\"attached\"}",
    );
    attach_batch[1] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        "screen",
    );
    try client.adoptFrameBatch(attach_batch);
    try testing.expectEqual(@as(usize, 4), slot.chunk_len);
    try testing.expectEqual(
        slot_mod.QueueClass.screen,
        slot.chunks[(slot.chunk_head + 3) % slot_mod.max_chunks_per_slot].class,
    );
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.detach\",\"params\":{\"stream_id\":1}}",
    );
    client.readReady(3);
    try testing.expect(!client.isClosing());
    try testing.expectEqual(@as(usize, 0), client.trackers.count());
    try testing.expectEqual(@as(usize, 0), slot.attached_streams);
    for (0..slot.chunk_len) |index| {
        const chunk = slot.chunks[(slot.chunk_head + index) % slot_mod.max_chunks_per_slot];
        try testing.expectEqual(slot_mod.QueueClass.control, chunk.class);
    }
}

test "reply-and-close waits through EAGAIN and closes only after full typed reply" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        9,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const filler: [64 * 1024]u8 = [_]u8{0xC3} ** (64 * 1024);
    while (true) {
        const rc = c.send(client.fd, &filler, filler.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) break;
        if (rc <= 0) return error.TestUnexpectedResult;
    }
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":1,\"protocol_max\":1,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    try testing.expect(client.close_after_flush != null);
    client.writeReady(2);
    try testing.expect(!client.isClosing());
    try testing.expect(drainNonblocking(fds[1]) != 0);
    client.writeReady(3);
    try testing.expect(client.isClosing());
}

test "socketpair read partial clock resets at the next frame boundary" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        10,
        &registry_value,
        &subscriptions,
        .{},
    );
    defer client.destroy();
    const optional = (protocol.Header{
        .kind = @enumFromInt(55_000),
        .flags = protocol.Flags.optional,
    }).encode();
    const hello = try framing.encodeFrame(testing.allocator, .{ .kind = .hello }, test_hello);
    defer testing.allocator.free(hello);
    _ = c.send(fds[1], &optional, 7, 0);
    client.readReady(0);
    const slot = try reactor.get(client.admission);
    try testing.expect(slot.partialExpired(.read, slot_mod.partial_deadline_ns));

    var remainder: [protocol.header_size - 7 + 7]u8 = undefined;
    @memcpy(remainder[0 .. protocol.header_size - 7], optional[7..]);
    @memcpy(remainder[protocol.header_size - 7 ..], hello[0..7]);
    _ = c.send(fds[1], &remainder, remainder.len, 0);
    client.readReady(20 * std.time.ns_per_s);
    try testing.expectEqual(
        @as(?u64, 20 * std.time.ns_per_s),
        slot.read_partial_started_ns,
    );
    try testing.expect(!slot.partialExpired(.read, 30 * std.time.ns_per_s - 1));
    try testing.expect(slot.partialExpired(.read, 30 * std.time.ns_per_s));
}
