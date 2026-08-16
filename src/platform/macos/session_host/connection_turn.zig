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
const process_seal_service = @import("process_seal_service.zig");

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
pub const admin_request_deadline_ns: u64 = 5 * std.time.ns_per_s;
pub const unattached_idle_deadline_ns: u64 = 30 * std.time.ns_per_s;

comptime {
    const max_snapshot_frames =
        (protocol.max_viewport_snapshot + protocol.max_binary_chunk - 1) /
        protocol.max_binary_chunk;
    if (slot_mod.resync_batch_bytes <
        protocol.max_viewport_snapshot + max_snapshot_frames * protocol.header_size)
        @compileError("resync queue cap cannot hold one maximum wire snapshot");
}

pub const Options = struct {
    runtime_ops: ?server.RuntimeOps = null,
    upgrade_ops: ?upgrade_wire.Ops = null,
    admission_gate: ?*upgrade.AdmissionGate = null,
    host_status: server.HostStatus = .{},
    live_host_status: ?*const server.HostStatus = null,
    admin_admission: ?*server.AdminAdmission = null,
    upgrade_preflight: ?OwnerUpgradePreflight = null,
    pressure_reclaim: ?OwnerPressureReclaim = null,
    controller_transition: ?OwnerControllerTransition = null,
    resize: ?OwnerResize = null,
    now_ns: u64 = 0,
    process_identity: ?process_seal_service.ReadyIdentity = null,
};

pub const OwnerUpgradePreflight = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, requester: *Client) bool,
};

pub const OwnerPressureReclaim = struct {
    ctx: *anyopaque,
    reclaim: *const fn (
        ctx: *anyopaque,
        requester: slot_mod.ConnectionKey,
        required_bytes: usize,
    ) bool,
};

pub const OwnerControllerTransition = struct {
    ctx: *anyopaque,
    /// Consumes every frame and the owning prepared token in `transition` on both success and
    /// failure. Caller must not discard or reuse any field after apply returns.
    apply: *const fn (
        ctx: *anyopaque,
        requester: *Client,
        transition: server.Action.ControllerTransitionRequested,
    ) bool,
};

pub const OwnerResize = struct {
    ctx: *anyopaque,
    /// Consumes every owned frame/body and the prepared token on both success and failure.
    apply: *const fn (
        ctx: *anyopaque,
        requester: *Client,
        resize: server.Action.ResizeRequested,
    ) bool,
};

pub const ScreenPressureCandidate = struct {
    stream: subscription_identity.LocalStreamId,
    tracker: slot_mod.ScreenTrackerKey,
    queued_bytes: usize,
    reclaimable_bytes: usize,
    written_prefix: bool,
};

const SubscriptionAdoption = enum {
    admitted,
    deferred_global_pressure,
    deferred_resync,
    rejected,
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
    admin_request_deadline_at_ns: ?u64 = null,
    upgrade_preflight: ?OwnerUpgradePreflight = null,
    pressure_reclaim: ?OwnerPressureReclaim = null,
    controller_transition: ?OwnerControllerTransition = null,
    resize: ?OwnerResize = null,
    sync_fail_once: bool = false,
    control_admission_fail_once: bool = false,
    producer_streams: []u64 = &.{},
    producer_sweep_cursor: usize = 0,
    pressure_reclaim_available: bool = false,
    projection_global_unavailable: bool = false,
    process_identity: ?process_seal_service.ReadyIdentity = null,

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
            .upgrade_preflight = options.upgrade_preflight,
            .pressure_reclaim = options.pressure_reclaim,
            .controller_transition = options.controller_transition,
            .resize = options.resize,
            .process_identity = options.process_identity,
        };
        self.connection.runtime_ops = options.runtime_ops;
        self.connection.upgrade_ops = options.upgrade_ops;
        self.connection.admin_admission = options.admin_admission;
        if (options.upgrade_preflight != null) {
            self.connection.upgrade_preflight = .{
                .ctx = self,
                .reserve = reserveServerUpgrade,
                .cancel = cancelServerUpgrade,
            };
        }
        self.connection.host_status = options.host_status;
        self.connection.live_host_status = options.live_host_status;
        self.connection.projection_budget = .{
            .ctx = self,
            .prepare = prepareProjectionBudget,
            .commit = commitProjectionBudget,
            .rollback = rollbackProjectionBudget,
            .release = releaseProjectionBudget,
        };
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
        self.allocator.free(self.producer_streams);
        self.parser.deinit();
        self.reactor.closeConnection(self.admission) catch unreachable;
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn wantsWrite(self: *Client) bool {
        const slot = self.reactor.get(self.admission) catch return false;
        return slot.firstPending() != null;
    }

    /// Owner-only pressure selection keeps protocol mutation in Client while exposing only the
    /// stable local stream identity and charged queued bytes.
    pub fn largestScreenPressure(self: *Client) ?ScreenPressureCandidate {
        const slot = self.reactor.get(self.admission) catch return null;
        if (!slot.writeBackpressured() or !slot.writeStallObserved()) return null;
        var result: ?ScreenPressureCandidate = null;
        var iterator = self.trackers.iterator();
        while (iterator.next()) |entry| {
            const state = slot.screenState(entry.value_ptr.*) catch continue;
            if (state != .valid and state != .resync_draining) continue;
            const queued = slot.screenResidentBytes(entry.value_ptr.*) catch continue;
            if (queued == 0) continue;
            if ((slot.preparedBaseBytes(entry.value_ptr.*) catch continue) != 0) continue;
            const retained = slot.retainedBaseBytes(entry.value_ptr.*) catch continue;
            const reclaimable = queued +| retained;
            const written_prefix = slot.trackerHasWrittenPrefix(entry.value_ptr.*) catch continue;
            if (written_prefix and
                (self.connection.streamHasInputCapability(entry.key_ptr.*) or
                    self.connection.hasInputCapability())) continue;
            if (result == null or queued > result.?.queued_bytes or
                (queued == result.?.queued_bytes and
                    (reclaimable > result.?.reclaimable_bytes or
                        (reclaimable == result.?.reclaimable_bytes and
                            entry.key_ptr.* < result.?.stream))))
                result = .{
                    .stream = entry.key_ptr.*,
                    .tracker = entry.value_ptr.*,
                    .queued_bytes = queued,
                    .reclaimable_bytes = reclaimable,
                    .written_prefix = written_prefix,
                };
        }
        return result;
    }

    pub fn acceptsPressureReclaim(self: *Client) bool {
        const slot = self.reactor.get(self.admission) catch return false;
        return !slot.writeBackpressured();
    }

    pub fn noteWriteStalled(self: *Client, now_ns: u64) void {
        const slot = self.reactor.get(self.admission) catch return;
        if (slot.firstPending() != null) slot.notePartial(.write, now_ns, false);
    }

    pub fn noteWriteReady(self: *Client) void {
        const slot = self.reactor.get(self.admission) catch return;
        slot.noteWriteReady();
    }

    /// The owner selected this connection as the global queued-screen pressure offender.
    /// Zero-prefix queues become one stream invalidation; partial-prefix queues fail-close.
    pub fn reclaimScreenPressure(self: *Client, candidate: ScreenPressureCandidate) bool {
        const tracker = self.trackers.get(candidate.stream) orelse return false;
        if (!std.meta.eql(tracker, candidate.tracker)) return false;
        self.invalidateSubscriptionOutput(candidate.stream, tracker);
        return true;
    }

    pub fn hasBufferedReadWork(self: *const Client) bool {
        return !self.isClosing() and self.close_after_flush == null and
            self.parser.bufferState() == .complete_or_error;
    }

    pub fn isClosing(self: *const Client) bool {
        return switch (self.state) {
            .open => false,
            .closing => true,
        };
    }

    pub fn isUpgradeDraining(self: *const Client) bool {
        return self.pending_upgrade != null or
            (self.close_after_flush orelse return false) == .upgrade_completed;
    }

    /// Kernel HUP/ERR/NVAL after the final readable bytes means no queued reply can be delivered.
    /// Cancel upgrade state if present, then converge through the canonical owner destroy path.
    pub fn peerBroken(self: *Client) void {
        self.failPendingUpgrade(.socket_error);
    }

    pub fn idleForUpgrade(self: *Client) bool {
        return self.upgradeReady(false);
    }

    pub fn requesterReadyForUpgrade(self: *Client) bool {
        return self.upgradeReady(true);
    }

    fn upgradeReady(self: *Client, requester: bool) bool {
        if (self.isClosing() or self.close_after_flush != null or
            self.pending_upgrade != null or self.armed_upgrade != null or
            self.parser.bufferState() != .empty or self.trackers.count() != 0 or
            self.connection.attachmentCount() != 0)
            return false;
        const slot = self.reactor.get(self.admission) catch return false;
        return if (requester)
            slot.requesterReadyForUpgrade()
        else
            slot.idleForUpgrade();
    }

    pub fn socketQuiescentForUpgrade(self: *Client) bool {
        var byte: [1]u8 = undefined;
        var interrupted: u8 = 0;
        while (interrupted < 4) : (interrupted += 1) {
            const rc = c.recv(self.fd, &byte, byte.len, posix.MSG.PEEK | posix.MSG.DONTWAIT);
            if (rc < 0 and posix.errno(rc) == .INTR) continue;
            return rc < 0 and posix.errno(rc) == .AGAIN;
        }
        return false;
    }

    /// Captures and sorts one cadence epoch exactly once. Subsequent owner turns consume one entry
    /// each, avoiding an allocation+sort and whole-stream scan for every subscription.
    pub fn beginProducerSweep(self: *Client, now_ns: u64) usize {
        self.allocator.free(self.producer_streams);
        self.producer_streams = self.connection.localStreams(self.allocator) catch {
            self.producer_streams = &.{};
            self.beginClose(.resource_exhausted);
            return 1;
        };
        std.mem.sort(u64, self.producer_streams, {}, std.sort.asc(u64));
        self.producer_sweep_cursor = 0;
        if (self.producer_streams.len == 0) return 1;

        const slot = self.reactor.get(self.admission) catch return 1;
        for (self.producer_streams, 0..) |candidate, index| {
            const candidate_tracker = self.trackers.get(candidate) orelse continue;
            const state = slot.screenState(candidate_tracker) catch continue;
            if (state == .invalidated and
                self.connection.resyncPending(candidate) and
                (slot.canAttemptResync(candidate_tracker) catch false) and
                (slot.resyncAttemptReady(candidate_tracker, now_ns) catch false))
            {
                self.producer_sweep_cursor = index;
                break;
            }
        }
        return self.producer_streams.len;
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
        if (!self.validateProcessIdentity()) return self.beginClose(.protocol_error);
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
                    self.dispatch(frame, now_ns) catch {
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
        if (!self.validateProcessIdentity()) return self.beginClose(.protocol_error);
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
        if (!self.validateProcessIdentity()) return self.beginClose(.protocol_error);
        if (self.isClosing()) return;
        self.pressure_reclaim_available = true;
        self.projection_global_unavailable = false;
        defer self.pressure_reclaim_available = false;
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        if (self.pending_upgrade != null and !self.wantsWrite()) {
            self.finalizePendingUpgrade();
            return;
        }
        if (!self.connection.handshakeComplete() and
            elapsedAtLeast(self.created_ns, now_ns, handshake_deadline_ns))
            return self.beginClose(.partial_timeout);
        if (self.admin_request_deadline_at_ns) |deadline|
            if (now_ns >= deadline) return self.beginClose(.partial_timeout);
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
        self.connection.expireCatchups(now_ns);
        if (self.producer_streams.len == 0 and self.trackers.count() != 0)
            _ = self.beginProducerSweep(now_ns);
        if (self.producer_streams.len == 0) return;
        // Exactly one captured producer candidate per owner turn. Missing trackers mean the
        // subscription detached after the cadence snapshot and are skipped without harming peers.
        const stream = self.producer_streams[
            self.producer_sweep_cursor % self.producer_streams.len
        ];
        self.producer_sweep_cursor =
            (self.producer_sweep_cursor + 1) % self.producer_streams.len;
        const tracker = self.trackers.get(stream) orelse return;
        if (self.connection.runtimeMissing(stream)) {
            self.notifyEndedAndRemoveTracker(stream);
            return;
        }
        var tracker_state = slot.screenState(tracker) catch
            return self.beginClose(.socket_error);
        if (!(slot.globalPressureReady(tracker, now_ns) catch
            return self.beginClose(.socket_error))) return;
        const resync_pending = self.connection.resyncPending(stream);
        if (resync_pending and tracker_state == .valid) {
            slot.invalidateAndPurgeScreenTracker(tracker) catch
                return self.beginClose(.socket_error);
            self.connection.markResyncDeliveryPurged(stream);
            tracker_state = .invalidated;
        }
        if (tracker_state == .resync_draining) return;
        if (tracker_state == .invalidated) {
            if (!resync_pending) return;
            if (!(slot.canAttemptResync(tracker) catch
                return self.beginClose(.socket_error))) return;
            if (!(slot.beginResyncAttempt(tracker, now_ns) catch
                return self.beginClose(.socket_error))) return;
        }
        var maybe_output = self.connection.collectOutputForLocalStream(stream) catch |err| {
            switch (err) {
                error.ProjectionBudgetUnavailable => {
                    if (self.projection_global_unavailable) {
                        slot.deferGlobalPressure(tracker, now_ns) catch
                            return self.beginClose(.socket_error);
                    } else if (tracker_state == .valid) {
                        self.invalidateSubscriptionOutput(stream, tracker);
                    }
                    return;
                },
                error.OutOfMemory => {
                    self.beginClose(.resource_exhausted);
                    return;
                },
            }
        };
        // Producer validation/revision terminals happen without an inbound peer frame. The
        // Connection marks itself closed after rolling back its projection; mirror that terminal
        // into the readiness owner immediately so poll_owner destroys the fd and all attachment
        // authority instead of treating `null` as an idle cadence forever.
        if (self.connection.isClosed())
            return self.beginClose(.resource_exhausted);
        if (maybe_output) |*output| {
            switch (self.tryAdoptSubscriptionTurn(stream, output.takeFrames())) {
                .admitted => output.commit(&self.connection),
                .deferred_global_pressure => {
                    output.rollback(&self.connection);
                    slot.deferGlobalPressure(tracker, now_ns) catch
                        return self.beginClose(.socket_error);
                },
                .deferred_resync => {
                    output.rollback(&self.connection);
                    slot.deferResyncAttempt(tracker, now_ns) catch
                        return self.beginClose(.socket_error);
                },
                .rejected => {
                    output.rollback(&self.connection);
                    if (!self.isClosing())
                        self.invalidateSubscriptionOutput(stream, tracker);
                },
            }
            if (self.isClosing()) return;
        } else if (!self.connection.hasLocalStream(stream)) {
            self.notifyEndedAndRemoveTracker(stream);
        }
        return;
    }

    fn notifyEndedAndRemoveTracker(self: *Client, stream: u64) void {
        if (!self.connection.supportsRuntimeEnded()) {
            self.connection.convergeEndedStream(stream);
            self.removeEndedTracker(stream);
            return;
        }
        const frame = self.connection.runtimeEndedFrame(stream) catch {
            self.connection.convergeEndedStream(stream);
            self.removeEndedTracker(stream);
            return self.beginClose(.resource_exhausted);
        };
        self.adoptControl(frame) catch return self.beginClose(.resource_exhausted);
        self.connection.convergeEndedStream(stream);
        self.removeEndedTracker(stream);
    }

    /// RuntimeNotFound is a stream lifecycle transition, not a transport failure. Purge its queued
    /// prefix and accounting without allocating, while preserving the shared client connection.
    fn removeEndedTracker(self: *Client, stream: u64) void {
        const tracker = self.trackers.fetchRemove(stream) orelse return;
        const slot = self.reactor.get(self.admission) catch
            return self.beginClose(.socket_error);
        slot.purgeAndDestroyScreenTracker(tracker.value) catch
            return self.beginClose(.socket_error);
        slot.detachStream() catch return self.beginClose(.socket_error);
    }

    /// A producer turn belongs to exactly one subscription. Ordinary output is admitted in order;
    /// any admission failure purges that subscription's unsent prefix and emits one control-reserve
    /// invalidation notice. An invalidated tracker may recover only through one atomic snapshot batch.
    fn adoptSubscriptionTurn(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
        frames: [][]u8,
    ) bool {
        switch (self.tryAdoptSubscriptionTurn(stream, frames)) {
            .admitted => return true,
            .deferred_resync => return false,
            .deferred_global_pressure, .rejected => {
                if (!self.isClosing()) {
                    const tracker = self.trackers.get(stream) orelse
                        return self.closeAndReject(.socket_error);
                    self.invalidateSubscriptionOutput(stream, tracker);
                }
                return false;
            },
        }
    }

    fn tryAdoptSubscriptionTurn(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
        frames: [][]u8,
    ) SubscriptionAdoption {
        defer self.allocator.free(frames);
        if (!validateSubscriptionBatch(stream, frames)) {
            for (frames) |bytes| self.allocator.free(bytes);
            _ = self.closeAndReject(.protocol_error);
            return .rejected;
        }
        const slot = self.reactor.get(self.admission) catch {
            _ = self.closeAndReject(.socket_error);
            return .rejected;
        };
        const tracker = self.trackers.get(stream) orelse {
            for (frames) |bytes| self.allocator.free(bytes);
            _ = self.closeAndReject(.socket_error);
            return .rejected;
        };
        const state = slot.screenState(tracker) catch {
            for (frames) |bytes| self.allocator.free(bytes);
            _ = self.closeAndReject(.socket_error);
            return .rejected;
        };
        if (state == .invalidated) {
            var snapshot_start: ?usize = null;
            for (frames, 0..) |bytes, index| {
                const class = server.classifyOutbound(bytes) catch unreachable;
                switch (class) {
                    .control => unreachable,
                    .subscription => |output| {
                        if (output.kind == .delta) {
                            for (frames) |owned| self.allocator.free(owned);
                            _ = self.closeAndReject(.protocol_error);
                            return .rejected;
                        }
                        if (output.kind == .snapshot and snapshot_start == null)
                            snapshot_start = index;
                    },
                }
            }
            const start = snapshot_start orelse {
                for (frames) |owned| self.allocator.free(owned);
                return .deferred_resync;
            };
            _ = start;
            // Metadata prefix and snapshot chunks share one atomic subscription batch. Keeping
            // their original order avoids a valid->draining transition between the two classes.
            slot.enqueueOwnedResyncSnapshot(tracker, frames) catch |err| switch (err) {
                error.SlotLimit, error.GlobalLimit, error.ChunkLimit => return .deferred_resync,
                error.OutOfMemory => {
                    _ = self.closeAndReject(.resource_exhausted);
                    return .rejected;
                },
                error.Stale, error.ScreenInvalidated => {
                    _ = self.closeAndReject(.socket_error);
                    return .rejected;
                },
            };
            return .admitted;
        }

        slot.enqueueOwnedScreenBatch(tracker, frames) catch |err| {
            if (err == error.GlobalLimit) {
                if (self.pressure_reclaim_available) if (self.pressure_reclaim) |ops| {
                    self.pressure_reclaim_available = false;
                    var total: usize = 0;
                    for (frames) |bytes| total +|= bytes.len;
                    if (ops.reclaim(ops.ctx, self.admission.key, total)) {
                        slot.enqueueOwnedScreenBatch(tracker, frames) catch |retry_err| {
                            for (frames) |bytes| self.allocator.free(bytes);
                            return if (retry_err == error.GlobalLimit)
                                .deferred_global_pressure
                            else
                                .rejected;
                        };
                        return .admitted;
                    }
                };
                for (frames) |bytes| self.allocator.free(bytes);
                return .deferred_global_pressure;
            }
            for (frames) |bytes| self.allocator.free(bytes);
            return .rejected;
        };
        return .admitted;
    }

    fn closeAndReject(self: *Client, reason: CloseReason) bool {
        self.beginClose(reason);
        return false;
    }

    fn invalidateSubscriptionOutput(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
        tracker: slot_mod.ScreenTrackerKey,
    ) void {
        const slot = self.reactor.get(self.admission) catch
            return self.beginClose(.socket_error);
        slot.invalidateAndPurgeScreenTracker(tracker) catch
            return self.beginClose(.socket_error);
        self.connection.markSubscriptionOutputInvalidated(stream);
        const notice = self.connection.snapshotInvalidatedFrame(stream) catch
            return self.beginClose(.resource_exhausted);
        self.adoptControl(notice) catch
            return self.beginClose(.resource_exhausted);
    }

    fn dispatch(self: *Client, frame: framing.Frame, now_ns: u64) error{OutOfMemory}!void {
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        var lease = if (self.admission_gate) |gate| gate.tryEnter() orelse {
            self.beginClose(.admission_closed);
            return;
        } else null;
        defer if (lease) |*held| held.release();
        slot.beginDispatch() catch return self.beginClose(.resource_exhausted);
        defer slot.endDispatch() catch unreachable;

        const was_admin = self.connection.isAdmin();
        if (was_admin) self.admin_request_deadline_at_ns = null;
        const action = try self.connection.handleFrameAt(frame, now_ns);
        if (!was_admin and self.connection.isAdmin())
            self.admin_request_deadline_at_ns = now_ns +| admin_request_deadline_ns;
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
            .admin_terminate_accepted => |accepted| {
                self.adoptControl(accepted.bytes) catch return error.OutOfMemory;
                const ops = self.connection.runtime_ops orelse
                    return self.beginClose(.socket_error);
                ops.terminate(ops.ctx, accepted.runtime_id);
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
                if (!self.upgrade_gate_closed) {
                    ops.cancel_unaccepted(ops.ctx, accepted.attempt_id);
                    self.allocator.free(accepted.bytes);
                    return self.beginClose(.upgrade_failed);
                }
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
            .resync_ack => |stream| {
                try self.syncTrackers();
                const tracker = self.trackers.get(stream) orelse
                    return self.beginClose(.socket_error);
                slot.deferResyncAttempt(tracker, now_ns) catch
                    return self.beginClose(.socket_error);
            },
            .frames => |frames| {
                try self.adoptFrameBatch(frames);
            },
            .prepared_attach => |prepared_value| {
                var prepared = prepared_value;
                try self.adoptPreparedAttach(&prepared);
            },
            .prepared_reply => |prepared_value| {
                var prepared = prepared_value;
                self.adoptControl(prepared.reply) catch {
                    prepared.output.rollback(&self.connection);
                    return error.OutOfMemory;
                };
                prepared.output.commit(&self.connection);
            },
            .catchup_arm_requested => |prepared_value| {
                var prepared = prepared_value;
                const identity = self.process_identity orelse
                    return self.beginClose(.protocol_error);
                if (!prepared.bindFinal(identity.pid, identity.process_nonce))
                    return self.beginClose(.protocol_error);
                self.adoptControl(prepared.reply) catch return error.OutOfMemory;
                if (!self.commitCatchupArm(&prepared))
                    return self.beginClose(.protocol_error);
            },
            .prepared_notification => |prepared| {
                self.adoptControl(prepared.reply) catch return error.OutOfMemory;
                const ops = self.connection.runtime_ops orelse
                    return self.beginClose(.socket_error);
                _ = ops.notification_commit(
                    ops.ctx,
                    prepared.runtime_id,
                    prepared.generation,
                );
            },
            .controller_transition_requested => |transition_value| {
                var transition = transition_value;
                const owner = self.controller_transition orelse {
                    self.allocator.free(transition.success_reply);
                    self.allocator.free(transition.stale_reply);
                    self.allocator.free(transition.exhausted_reply);
                    if (transition.revocation) |revocation|
                        self.allocator.free(revocation.frame);
                    self.connection.discardPreparedControllerTransition(
                        &transition.prepared,
                    );
                    return self.beginClose(.resource_exhausted);
                };
                if (!owner.apply(owner.ctx, self, transition))
                    return self.beginClose(.resource_exhausted);
            },
            .resize_requested => |resize_value| {
                var resize = resize_value;
                const owner = self.resize orelse {
                    self.connection.discardPreparedResize(&resize);
                    return self.beginClose(.resource_exhausted);
                };
                if (!owner.apply(owner.ctx, self, resize))
                    return self.beginClose(.resource_exhausted);
            },
        }
    }

    fn adoptPreparedAttach(
        self: *Client,
        prepared: *server.Action.PreparedAttach,
    ) error{OutOfMemory}!void {
        const stream = prepared.output.stream;
        self.syncTrackers() catch {
            self.allocator.free(prepared.reply);
            prepared.output.rollback(&self.connection);
            self.connection.rollbackPreparedAttach(stream);
            return error.OutOfMemory;
        };
        self.adoptControl(prepared.reply) catch {
            prepared.output.rollback(&self.connection);
            self.connection.rollbackPreparedAttach(stream);
            return error.OutOfMemory;
        };
        const adopted = self.tryAdoptSubscriptionTurn(
            stream,
            prepared.output.takeFrames(),
        );
        if (adopted != .admitted) {
            prepared.output.rollback(&self.connection);
            self.connection.rollbackPreparedAttach(stream);
            return self.beginClose(.resource_exhausted);
        }
        prepared.output.commit(&self.connection);
    }

    fn adoptFrameBatch(self: *Client, frames: [][]u8) error{OutOfMemory}!void {
        defer self.allocator.free(frames);
        if (frames.len == 0) return;
        var remaining_start: usize = 0;
        errdefer for (frames[remaining_start..]) |bytes| self.allocator.free(bytes);
        try self.syncTrackers();
        remaining_start = 1;
        try self.adoptControl(frames[0]);
        if (frames.len == 1) return;
        const class = server.classifyOutbound(frames[1]) catch {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return error.OutOfMemory;
        };
        const stream = switch (class) {
            .control => {
                for (frames[1..]) |bytes| self.allocator.free(bytes);
                remaining_start = frames.len;
                return error.OutOfMemory;
            },
            .subscription => |output| blk: {
                if (output.kind != .snapshot) {
                    for (frames[1..]) |bytes| self.allocator.free(bytes);
                    remaining_start = frames.len;
                    return error.OutOfMemory;
                }
                break :blk output.stream;
            },
        };
        if (!validateSubscriptionBatch(stream, frames[1..])) {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return error.OutOfMemory;
        }
        const slot = self.reactor.get(self.admission) catch {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return self.beginClose(.socket_error);
        };
        const tracker = self.trackers.get(stream) orelse {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return self.beginClose(.socket_error);
        };
        slot.invalidateScreen(tracker) catch {
            for (frames[1..]) |bytes| self.allocator.free(bytes);
            remaining_start = frames.len;
            return self.beginClose(.socket_error);
        };
        remaining_start = frames.len;
        slot.enqueueOwnedResyncSnapshot(tracker, frames[1..]) catch {
            // Attach bootstrap has no RemoteRuntime pump yet to acknowledge invalidation. Fail the
            // connection so the controller lease is revoked instead of leaving readSnapshot hung.
            self.beginClose(.resource_exhausted);
        };
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
            _ = try self.ensureTracker(stream);
        }
    }

    pub fn screenTracker(self: *const Client, stream: u64) ?slot_mod.ScreenTrackerKey {
        return self.trackers.get(stream);
    }

    fn ensureTracker(
        self: *Client,
        stream: subscription_identity.LocalStreamId,
    ) error{OutOfMemory}!slot_mod.ScreenTrackerKey {
        if (self.trackers.get(stream)) |tracker| return tracker;
        const slot = self.reactor.get(self.admission) catch return error.OutOfMemory;
        const tracker = slot.createScreenTracker() catch return error.OutOfMemory;
        errdefer slot.destroyScreenTracker(tracker) catch unreachable;
        self.trackers.put(self.allocator, stream, tracker) catch
            return error.OutOfMemory;
        slot.attachStream() catch {
            _ = self.trackers.remove(stream);
            return error.OutOfMemory;
        };
        return tracker;
    }

    fn prepareProjectionBudget(
        ctx: *anyopaque,
        stream: subscription_identity.LocalStreamId,
        upper_bound: usize,
    ) ?slot_mod.BaseReservation {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const tracker = self.ensureTracker(stream) catch return null;
        const slot = self.reactor.get(self.admission) catch return null;
        return slot.reserveBaseUpdate(tracker, upper_bound) catch |err| {
            if (err != error.GlobalLimit) return null;
            if ((slot.screenState(tracker) catch return null) != .valid) {
                self.projection_global_unavailable = true;
                return null;
            }
            if (!self.pressure_reclaim_available) {
                self.projection_global_unavailable = true;
                return null;
            }
            const ops = self.pressure_reclaim orelse {
                self.projection_global_unavailable = true;
                return null;
            };
            self.pressure_reclaim_available = false;
            if (!ops.reclaim(ops.ctx, self.admission.key, upper_bound)) {
                self.projection_global_unavailable = true;
                return null;
            }
            return slot.reserveBaseUpdate(tracker, upper_bound) catch |retry_err| {
                if (retry_err == error.GlobalLimit)
                    self.projection_global_unavailable = true;
                return null;
            };
        };
    }

    fn commitProjectionBudget(
        ctx: *anyopaque,
        reservation: slot_mod.BaseReservation,
        actual: usize,
    ) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const slot = self.reactor.get(self.admission) catch unreachable;
        slot.commitBaseUpdate(reservation, actual) catch unreachable;
    }

    fn rollbackProjectionBudget(
        ctx: *anyopaque,
        reservation: slot_mod.BaseReservation,
    ) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const slot = self.reactor.get(self.admission) catch unreachable;
        slot.rollbackBaseUpdate(reservation) catch unreachable;
    }

    fn releaseProjectionBudget(
        ctx: *anyopaque,
        stream: subscription_identity.LocalStreamId,
    ) void {
        const self: *Client = @ptrCast(@alignCast(ctx));
        const tracker = self.trackers.get(stream) orelse return;
        const slot = self.reactor.get(self.admission) catch unreachable;
        slot.releaseBaseState(tracker) catch unreachable;
    }

    fn validateProcessIdentity(self: *const Client) bool {
        const expected = self.process_identity orelse return true;
        const current = process_seal_service.currentReadyIdentity() catch return false;
        return std.meta.eql(expected, current);
    }

    fn commitCatchupArm(
        self: *Client,
        prepared: *server.Action.PreparedCatchupArm,
    ) bool {
        if (prepared.self_addr != @intFromPtr(prepared) or prepared.active_raw != 1)
            return false;
        const expected_process = self.process_identity orelse return false;
        const current_process = process_seal_service.currentReadyIdentity() catch return false;
        if (!std.meta.eql(expected_process, current_process) or
            prepared.pid != current_process.pid or
            prepared.process_nonce != current_process.process_nonce or
            !self.connection.runtime_catchup_barrier_v1) return false;
        const owner = self.connection.subscription_identity orelse return false;
        const sub = self.connection.attachments.getPtr(prepared.stream) orelse return false;
        if (!registry.Capability.has(
            self.connection.registry.capabilitiesOfSubscription(
                sub.runtime_id,
                sub.subscription_id,
            ),
            registry.Capability.observe,
        ) or
            prepared.identity.host_id != self.connection.host_id or
            prepared.identity.subscription.value != sub.subscription_id.value or
            prepared.identity.runtime_id != sub.runtime_id or
            !std.meta.eql(prepared.identity.connection, owner.connection) or
            !std.meta.eql(sub.catchup, prepared.before)) return false;
        var recomputed = prepared.before;
        const result = recomputed.arm(
            prepared.identity,
            prepared.now_ns,
            prepared.expires_at_ns,
        );
        if (result != prepared.result or !std.meta.eql(recomputed, prepared.after)) return false;
        sub.catchup = prepared.after;
        prepared.active_raw = 0;
        return true;
    }

    fn adoptControl(self: *Client, bytes: []u8) error{OutOfMemory}!void {
        if (self.control_admission_fail_once) {
            self.control_admission_fail_once = false;
            self.allocator.free(bytes);
            return error.OutOfMemory;
        }
        const slot = self.reactor.get(self.admission) catch return self.beginClose(.socket_error);
        slot.enqueueOwnedControl(bytes) catch {
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

fn reserveServerUpgrade(ctx: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(ctx));
    const preflight = client.upgrade_preflight orelse return false;
    const gate = client.admission_gate orelse return false;
    if (!gate.close()) return false;
    client.upgrade_gate_closed = true;
    if (preflight.check(preflight.ctx, client)) return true;
    cancelServerUpgrade(ctx);
    return false;
}

fn cancelServerUpgrade(ctx: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(ctx));
    if (!client.upgrade_gate_closed) return;
    client.admission_gate.?.cancelClose();
    client.upgrade_gate_closed = false;
}

fn validateSubscriptionBatch(
    expected_stream: subscription_identity.LocalStreamId,
    frames: []const []const u8,
) bool {
    var snapshot_batch: ?bool = null;
    var screen_started = false;
    for (frames, 0..) |bytes, index| {
        if (bytes.len < protocol.header_size) return false;
        const header_bytes: *const [protocol.header_size]u8 = @ptrCast(bytes.ptr);
        const header = protocol.Header.decode(header_bytes) catch return false;
        const class = server.classifyOutbound(bytes) catch return false;
        const output = switch (class) {
            .control => return false,
            .subscription => |subscription| subscription,
        };
        if (output.stream != expected_stream or header.major != protocol.version_major)
            return false;
        switch (output.kind) {
            .event => {
                if (screen_started or header.flags != 0) return false;
            },
            .snapshot, .delta => {
                const is_snapshot = output.kind == .snapshot;
                if (snapshot_batch) |existing| {
                    if (existing != is_snapshot) return false;
                } else snapshot_batch = is_snapshot;
                screen_started = true;
                if (header.flags & ~protocol.Flags.end_stream != 0) return false;
                const ends = protocol.Flags.hasEndStream(header.flags);
                if (ends != (index + 1 == frames.len)) return false;
            },
            // Dormant wire vocabulary only. The product path must remain closed until a sealed
            // PreparedCatchupBatch binds the decoded payload to the projection and pending row.
            .barrier => return false,
        }
    }
    return true;
}

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
            .probe_prepare = upgrade_wire.requiresPreflight,
            .stage_pending = stage,
            .cancel_unaccepted = cancel,
            .arm_accepted = arm,
            .abort_armed = upgrade_wire.cannotAbortArmed,
            .status = status,
        };
    }
};

fn allowReadyTestUpgrade(_: *anyopaque, requester: *Client) bool {
    return requester.requesterReadyForUpgrade() and requester.socketQuiescentForUpgrade();
}

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

fn sendTestStreamFrame(
    fd: c.fd_t,
    kind: protocol.Kind,
    stream_id: u64,
    payload: []const u8,
) !void {
    const wire = try framing.encodeFrame(std.testing.allocator, .{
        .kind = kind,
        .stream_id = stream_id,
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

fn receiveIntoParserNonblocking(fd: c.fd_t, parser: *framing.FrameParser) !usize {
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
        if (rc < 0 and posix.errno(rc) == .AGAIN) return total;
        if (rc <= 0) return total;
        const len: usize = @intCast(rc);
        try parser.push(buf[0..len]);
        total += len;
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
            .upgrade_preflight = .{ .ctx = &owner, .check = allowReadyTestUpgrade },
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
            .upgrade_preflight = .{ .ctx = &owner, .check = allowReadyTestUpgrade },
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

test "product attach admission failure and EOF release retained projection authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            61,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
        );
        client.readReady(1);
        client.control_admission_fail_once = true;
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
        );
        client.readReady(2);
        try testing.expect(client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
        try testing.expectEqual(
            @as(u64, 0),
            registry_value.get(0xAA).?.controller_generation,
        );
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            64,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(fds[1], .hello, 1, test_hello);
        client.readReady(1);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        const slot = try reactor.get(client.admission);
        const tracker = client.trackers.get(1).?;
        try testing.expect((try slot.retainedBaseBytes(tracker)) > 0);
        try sendTestFrame(
            fds[1],
            .request,
            3,
            "{\"method\":\"runtime.detach\",\"params\":{\"stream_id\":1}}",
        );
        client.readReady(3);
        try testing.expect(!client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
        try testing.expectEqual(@as(usize, 0), client.trackers.count());
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            63,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(fds[1], .hello, 1, test_hello);
        client.readReady(1);
        const slot = try reactor.get(client.admission);
        try slot.consumeWritten(slot.pending_bytes);
        for (slot.chunk_len..slot_mod.max_chunks_per_slot - 1) |_|
            try slot.enqueueControl("x");
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        try testing.expect(client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            62,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
        );
        client.readReady(1);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        const slot = try reactor.get(client.admission);
        const tracker = client.trackers.get(1).?;
        try testing.expect((try slot.retainedBaseBytes(tracker)) > 0);
        try slot.consumeWritten(slot.pending_bytes);
        runtime_ops.observation_version = 1;
        try sendTestFrame(
            fds[1],
            .request,
            3,
            "{\"method\":\"runtime.observation\",\"params\":{\"stream_id\":1}}",
        );
        client.readReady(3);
        try testing.expect(!client.isClosing());
        try testing.expectEqual(@as(usize, 0), try slot.preparedBaseBytes(tracker));
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        const observed = client.connection.attachments.get(1).?;
        try testing.expectEqual(
            observed.base.?.len + observed.observation_base.?.len,
            try slot.retainedBaseBytes(tracker),
        );
        client.peerBroken();
        try testing.expect(client.isClosing());
        client.destroy();
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), registry_value.attachmentCount());
    }
}

test "CR4a host admission은 control queue 성공 뒤 pending을 게시하고 expiry를 연장하지 않는다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const allocator = testing.allocator;
    var registry_value = registry.TerminalRuntimeRegistry.init(allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const process_identity = process_seal_service.currentReadyIdentity() catch |err| switch (err) {
        error.NotReady => ready: {
            const process_pid = process_seal_service.currentProcessId();
            const process_nonce = try process_seal_service.generateProcessNonce();
            process_seal_service.commitReady(try process_seal_service.prepare(process_pid, process_nonce));
            break :ready try process_seal_service.currentReadyIdentity();
        },
        else => return err,
    };
    const nonce = "00112233445566778899aabbccddeeff";
    const request =
        "{\"method\":\"runtime.catchup\",\"params\":{\"stream_id\":1,\"request_nonce\":\"" ++
        nonce ++ "\"}}";
    const expectReply = struct {
        fn contains(fd: c.fd_t, needle: []const u8) !void {
            var parser = framing.FrameParser.init(testing.allocator);
            defer parser.deinit();
            _ = try receiveIntoParserNonblocking(fd, &parser);
            var found = false;
            while (try parser.next()) |frame| {
                defer frame.deinit(testing.allocator);
                if (std.mem.indexOf(u8, frame.payload, needle) != null) found = true;
            }
            try testing.expect(found);
        }
    }.contains;
    const prepareDirect = struct {
        fn one(client: *Client, now_ns: u64, request_id: u64, payload: []const u8) !server.Action.PreparedCatchupArm {
            const wire = try framing.encodeFrame(
                testing.allocator,
                .{ .kind = .request, .request_id = request_id },
                payload,
            );
            defer testing.allocator.free(wire);
            var parser = framing.FrameParser.init(testing.allocator);
            defer parser.deinit();
            try parser.push(wire);
            const frame = (try parser.next()).?;
            defer frame.deinit(testing.allocator);
            const action = try client.connection.handleFrameAt(frame, now_ns);
            if (action != .catchup_arm_requested) return error.TestUnexpectedResult;
            return action.catchup_arm_requested;
        }
    }.one;

    // Capability absence is a product negative: the request gets a typed denial and cannot arm
    // the subscription even though the observer attachment itself is otherwise valid.
    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[]}",
        );
        client.readReady(1);
        client.writeReady(1);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        client.writeReady(2);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(fds[1], .request, 3, request);
        client.readReady(3);
        client.writeReady(3);
        try expectReply(fds[1], "unauthorized");
        try testing.expect(client.connection.attachments.get(1).?.catchup == .idle);
    }

    // A mixed-type capabilities array is malformed, not a permissive negotiation surface.
    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[{},\"runtime_catchup_barrier_v1\"]}",
        );
        client.readReady(1);
        try testing.expect(client.isClosing());
        try testing.expectEqual(@as(usize, 0), client.connection.attachments.count());
        client.destroy();
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_catchup_barrier_v1\"]}",
        );
        client.readReady(1);
        client.writeReady(1);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(2);
        client.writeReady(2);
        _ = drainNonblocking(fds[1]);
        client.control_admission_fail_once = true;
        try sendTestFrame(fds[1], .request, 3, request);
        client.readReady(3);
        try testing.expect(client.isClosing());
        try testing.expect(client.connection.attachments.get(1).?.catchup == .idle);
        client.destroy();
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        const client = try Client.create(
            allocator,
            fds[0],
            reactor,
            0x1234,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops(), .process_identity = process_identity },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_catchup_barrier_v1\"]}",
        );
        client.readReady(10);
        client.writeReady(10);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
        );
        client.readReady(11);
        client.writeReady(11);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(fds[1], .request, 3, request);
        client.readReady(12);
        const pending = client.connection.attachments.get(1).?.catchup.pending;
        try testing.expectEqual(@as(u64, 12 + server.catchup_host_expiry_ns), pending.expires_at_ns);
        client.writeReady(12);
        _ = drainNonblocking(fds[1]);

        // The response queue owner is the only product caller, but this same-module hostile seam
        // proves that its final-address receipt cannot be copied, drifted, or replayed.
        var prepared = try prepareDirect(client, 12, 40, request);
        defer allocator.free(prepared.reply);
        try testing.expect(prepared.bindFinal(process_identity.pid, process_identity.process_nonce));
        const state_before_hostile = client.connection.attachments.get(1).?.catchup;
        var copied = prepared;
        try testing.expect(!client.commitCatchupArm(&copied));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);
        prepared.pid +%= 1;
        try testing.expect(!client.commitCatchupArm(&prepared));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);
        prepared.pid -%= 1;
        prepared.process_nonce +%= 1;
        try testing.expect(!client.commitCatchupArm(&prepared));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);
        prepared.process_nonce -%= 1;
        try testing.expect(client.commitCatchupArm(&prepared));
        try testing.expectEqual(@as(u8, 0), prepared.active_raw);
        try testing.expect(!client.commitCatchupArm(&prepared));
        try testing.expectEqualDeep(state_before_hostile, client.connection.attachments.get(1).?.catchup);

        try sendTestFrame(fds[1], .request, 4, request);
        client.readReady(13);
        try testing.expectEqualDeep(pending, client.connection.attachments.get(1).?.catchup.pending);
        client.writeReady(13);
        try expectReply(fds[1], "idempotent");

        const foreign_request =
            "{\"method\":\"runtime.catchup\",\"params\":{\"stream_id\":1,\"request_nonce\":\"ffeeddccbbaa99887766554433221100\"}}";
        try sendTestFrame(fds[1], .request, 5, foreign_request);
        client.readReady(14);
        try testing.expectEqualDeep(pending, client.connection.attachments.get(1).?.catchup.pending);
        client.writeReady(14);
        try expectReply(fds[1], "busy");

        client.tick(pending.expires_at_ns - 1);
        try testing.expect(client.connection.attachments.get(1).?.catchup == .pending);
        try sendTestFrame(fds[1], .request, 6, request);
        client.readReady(pending.expires_at_ns);
        client.writeReady(pending.expires_at_ns);
        try expectReply(fds[1], "expired");
        try testing.expect(client.connection.attachments.get(1).?.catchup == .terminal);
    }
}

test "notification consume commits only after response control admission" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    var fds: [2]c_int = undefined;
    try testing.expectEqual(
        @as(c_int, 0),
        c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
    );
    defer _ = c.close(fds[1]);
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        71,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(3);
    client.writeReady(4);
    _ = drainNonblocking(fds[1]);

    client.control_admission_fail_once = true;
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.notification\",\"params\":{\"stream_id\":1}}",
    );
    client.readReady(5);
    try testing.expectEqual(@as(usize, 1), runtime_ops.notification_calls);
    try testing.expectEqual(@as(usize, 0), runtime_ops.notification_commit_calls);
    try testing.expect(client.isClosing());
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

test "missing runtime converges attachment identity tracker and queued screen in one turn" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = std.math.maxInt(usize) },
    );
    const allocator = failing.allocator();
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var subscriptions = subscription_identity.Table.init(allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        allocator,
        fds[0],
        reactor,
        82,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_ended_v1\"]}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    const tracker = client.trackers.get(1).?;
    const attached = client.connection.attachments.get(1).?;
    const attached_retained = attached.base.?.len +
        (if (attached.observation_base) |base| base.len else 0);
    try testing.expectEqual(
        attached_retained,
        try slot.retainedBaseBytes(tracker),
    );
    try testing.expectEqual(@as(usize, 0), try slot.preparedBaseBytes(tracker));
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try slot.consumeWritten(slot.pending_bytes);
    try slot.enqueueScreen(tracker, "stale-screen");
    try testing.expectEqual(@as(usize, 1), client.connection.attachmentCount());
    try testing.expectEqual(@as(usize, 1), subscriptions.count());
    try testing.expectEqual(@as(usize, 1), slot.attached_streams);

    // Pressure invalidation waits for a stream ACK and used to return before consulting the
    // registry, stranding authority forever if another client terminated the runtime meanwhile.
    try slot.invalidateAndPurgeScreenTracker(tracker);
    client.connection.markSubscriptionOutputInvalidated(1);
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    try testing.expect(!client.connection.resyncPending(1));
    _ = client.beginProducerSweep(3);
    registry_value.unregister(0xAA);
    runtime_ops.runtime_missing = true;
    // Ended convergence itself is allocation-free; a starved allocator cannot strand ownership.
    failing.fail_index = failing.alloc_index;
    client.tick(3);

    try testing.expect(client.isClosing());
    try testing.expectEqual(@as(usize, 0), client.connection.attachmentCount());
    try testing.expectEqual(@as(usize, 0), subscriptions.count());
    try testing.expectEqual(@as(usize, 0), client.trackers.count());
    try testing.expectEqual(@as(usize, 0), slot.attached_streams);
    try testing.expectEqual(@as(usize, 0), slot.chunk_len);
    try testing.expectEqual(@as(usize, 0), slot.pending_bytes);
}

test "subscription pressure emits one control notice and recovers with an atomic snapshot" {
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
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        81,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    var client_alive = true;
    defer if (client_alive) client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    const tracker = client.trackers.get(1).?;
    try slot.consumeWritten(slot.pending_bytes);
    runtime_ops.snapshot_len = 2 * 1024 * 1024 + 17;
    try testing.expectEqual(slot_mod.ScreenState.valid, try slot.screenState(tracker));

    try slot.enqueueScreen(tracker, "controller-zero-prefix");
    slot.notePartial(.write, 10, false);
    const controller_candidate = client.largestScreenPressure().?;
    try testing.expectEqual(@as(u64, 1), controller_candidate.stream);
    try testing.expect(std.meta.eql(tracker, controller_candidate.tracker));
    try testing.expect(!controller_candidate.written_prefix);
    try testing.expect(registry.Capability.has(
        registry_value.capabilitiesOfSubscription(
            0xAA,
            client.connection.attachments.get(1).?.subscription_id,
        ),
        registry.Capability.input,
    ));
    slot.clearPartial(.write);
    try slot.consumeWritten("controller-zero-prefix".len);

    try slot.enqueueScreen(tracker, "controller-written-prefix");
    try slot.consumeWritten(1);
    slot.notePartial(.write, 20, false);
    try testing.expect(client.largestScreenPressure() == null);
    slot.clearPartial(.write);
    try slot.consumeWritten("controller-written-prefix".len - 1);

    for (0..slot_mod.max_chunks_per_slot - slot_mod.control_chunk_reserve - slot.chunk_len) |_| try slot.enqueueScreen(tracker, "queued");

    const overflowing = try testing.allocator.alloc([]u8, 1);
    overflowing[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        "overflow",
    );
    try testing.expect(!client.adoptSubscriptionTurn(1, overflowing));
    try testing.expect(!client.isClosing());
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    try testing.expect(registry.Capability.has(
        registry_value.capabilitiesOfSubscription(
            0xAA,
            client.connection.attachments.get(1).?.subscription_id,
        ),
        registry.Capability.input,
    ));
    try testing.expectEqual(@as(usize, 0), try slot.retainedBaseBytes(tracker));
    var notice_count: usize = 0;
    for (0..slot.chunk_len) |logical| {
        const chunk = slot.chunks[(slot.chunk_head + logical) % slot_mod.max_chunks_per_slot];
        try testing.expectEqual(slot_mod.QueueClass.control, chunk.class);
        if (std.mem.indexOf(u8, chunk.bytes, "snapshot.invalidated") != null)
            notice_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), notice_count);
    var notice_parser = framing.FrameParser.init(testing.allocator);
    defer notice_parser.deinit();
    client.writeReady(3);
    try testing.expect((try receiveIntoParserNonblocking(fds[1], &notice_parser)) != 0);
    var wire_notices: usize = 0;
    while (try notice_parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(protocol.Kind.event, frame.header.kind);
        try testing.expectEqual(@as(u64, 1), frame.header.stream_id);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "snapshot.invalidated") != null);
        wire_notices += 1;
    }
    try testing.expectEqual(@as(usize, 1), wire_notices);
    try testing.expect(!client.connection.attachments.get(1).?.resync_pending);
    try sendTestStreamFrame(fds[1], .stream_ack, 1, "{\"action\":\"resync\"}");
    const ack_at: u64 = 4;
    client.readReady(ack_at);
    try testing.expect(client.connection.attachments.get(1).?.resync_pending);
    try sendTestStreamFrame(fds[1], .stream_ack, 1, "{\"action\":\"resync\"}");
    client.readReady(ack_at + 1);
    client.tick(ack_at + slot_mod.resync_retry_backoff_ns - 1);
    try testing.expectEqual(@as(usize, 1), runtime_ops.snapshot_calls);
    try testing.expectEqual(slot_mod.ScreenState.invalidated, try slot.screenState(tracker));
    client.tick(ack_at + slot_mod.resync_retry_backoff_ns);
    try testing.expectEqual(@as(usize, 2), runtime_ops.snapshot_calls);
    try testing.expect(!client.isClosing());
    try testing.expectEqual(slot_mod.ScreenState.resync_draining, try slot.screenState(tracker));
    try testing.expect(!client.connection.attachments.get(1).?.resync_pending);
    try sendTestStreamFrame(fds[1], .stream_ack, 1, "{\"action\":\"resync\"}");
    client.readReady(ack_at + slot_mod.resync_retry_backoff_ns + 1);
    try testing.expect(!client.connection.attachments.get(1).?.resync_pending);
    try testing.expect((try slot.screenResidentBytes(tracker)) > 0);
    var recovered_chunks: usize = 0;
    for (0..slot.chunk_len) |logical| {
        const chunk = slot.chunks[(slot.chunk_head + logical) % slot_mod.max_chunks_per_slot];
        if (chunk.class == .screen) recovered_chunks += 1;
    }
    try testing.expectEqual(@as(usize, 4), recovered_chunks);
    const recovered = client.connection.attachments.get(1).?;
    const recovered_retained = recovered.base.?.len +
        (if (recovered.observation_base) |base| base.len else 0);
    try testing.expectEqual(
        recovered_retained,
        try slot.retainedBaseBytes(tracker),
    );
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    var recovery_parser = framing.FrameParser.init(testing.allocator);
    defer recovery_parser.deinit();
    const recovery_write_at = ack_at + slot_mod.resync_retry_backoff_ns + 2;
    client.writeReady(recovery_write_at);
    _ = try receiveIntoParserNonblocking(fds[1], &recovery_parser);
    try testing.expect(slot.pending_bytes != 0);
    try testing.expectEqual(
        slot_mod.ScreenState.resync_draining,
        try slot.screenState(tracker),
    );
    var write_attempts: usize = 1;
    while (slot.pending_bytes != 0 and write_attempts < 1024) : (write_attempts += 1) {
        client.writeReady(recovery_write_at + write_attempts);
        _ = try receiveIntoParserNonblocking(fds[1], &recovery_parser);
    }
    try testing.expectEqual(@as(usize, 0), slot.pending_bytes);
    try testing.expect(write_attempts < 1024);
    _ = try receiveIntoParserNonblocking(fds[1], &recovery_parser);
    var metadata_frames: usize = 0;
    var snapshot_frames: usize = 0;
    var snapshot_bytes: usize = 0;
    var wire_index: usize = 0;
    while (try recovery_parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 1), frame.header.stream_id);
        switch (frame.header.kind) {
            .event => {
                try testing.expectEqual(@as(usize, 0), wire_index);
                metadata_frames += 1;
            },
            .snapshot_chunk => {
                snapshot_frames += 1;
                try testing.expectEqual(snapshot_frames, wire_index);
                snapshot_bytes += frame.payload.len;
                try testing.expectEqual(
                    snapshot_frames == 3,
                    protocol.Flags.hasEndStream(frame.header.flags),
                );
            },
            else => return error.TestUnexpectedResult,
        }
        wire_index += 1;
    }
    try testing.expectEqual(@as(usize, 1), metadata_frames);
    try testing.expectEqual(@as(usize, 3), snapshot_frames);
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024 + 17), snapshot_bytes);
    try testing.expectEqual(slot_mod.ScreenState.valid, try slot.screenState(tracker));
    client.destroy();
    client_alive = false;
    try testing.expectEqual(@as(usize, 0), subscriptions.count());
    try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.shared_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
}

test "periodic producer terminals immediately close readiness ownership and release attachment" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const modes = [_]enum { invalid_observation, encoded_overflow, revision_exhaustion }{
        .invalid_observation,
        .encoded_overflow,
        .revision_exhaustion,
    };
    for (modes) |mode| {
        var fds: [2]c_int = undefined;
        var sibling_fds: [2]c_int = undefined;
        try testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds),
        );
        try testing.expectEqual(
            @as(c_int, 0),
            c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sibling_fds),
        );
        var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
        defer registry_value.deinit();
        _ = try registry_value.register(0xAA, 80, 24);
        _ = try registry_value.register(0xBB, 80, 24);
        var subscriptions = subscription_identity.Table.init(testing.allocator);
        defer subscriptions.deinit();
        const reactor = try slot_mod.ReactorCore.create(testing.allocator);
        defer reactor.destroy();
        var runtime_ops: server.FakeRuntimeOps = .{};
        var sibling_ops: server.FakeRuntimeOps = .{};
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            90,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = runtime_ops.ops() },
        );
        var client_alive = true;
        defer if (client_alive) client.destroy();
        const sibling = try Client.create(
            testing.allocator,
            sibling_fds[0],
            reactor,
            91,
            &registry_value,
            &subscriptions,
            .{ .runtime_ops = sibling_ops.ops() },
        );
        var sibling_alive = true;
        defer if (sibling_alive) sibling.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"]}",
        );
        client.readReady(1);
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
        );
        client.readReady(2);
        try sendTestFrame(
            sibling_fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
        );
        sibling.readReady(1);
        try sendTestFrame(
            sibling_fds[1],
            .request,
            2,
            "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"controller\"}}",
        );
        sibling.readReady(2);
        const slot = try reactor.get(client.admission);
        try slot.consumeWritten(slot.pending_bytes);
        const sibling_slot = try reactor.get(sibling.admission);
        try sibling_slot.consumeWritten(sibling_slot.pending_bytes);
        runtime_ops.observation_urgent = true;
        switch (mode) {
            .invalid_observation => runtime_ops.observation_invalid = .mouse_mode,
            .encoded_overflow => runtime_ops.observation_invalid = .encoded_escape_expansion,
            .revision_exhaustion => {
                runtime_ops.observation_version = 1;
                client.connection.attachments.getPtr(1).?.observation_revision =
                    std.math.maxInt(u64);
            },
        }
        _ = client.beginProducerSweep(10);
        client.tick(10);
        try testing.expect(client.isClosing());
        sibling.tick(10);
        try testing.expect(!sibling.isClosing());
        try testing.expectEqual(@as(usize, 2), subscriptions.count());

        client.destroy();
        client_alive = false;
        try testing.expectEqual(@as(usize, 1), subscriptions.count());
        try sendTestFrame(sibling_fds[1], .ping, 3, "still-alive");
        sibling.readReady(11);
        try testing.expect(!sibling.isClosing());
        sibling.destroy();
        sibling_alive = false;
        try testing.expectEqual(@as(usize, 0), subscriptions.count());
        try testing.expectEqual(@as(usize, 0), reactor.budget.resident_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.shared_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
        try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
        var byte: [1]u8 = undefined;
        try testing.expectEqual(@as(isize, 0), c.recv(fds[1], &byte, byte.len, 0));
        try testing.expectEqual(@as(isize, 0), c.recv(sibling_fds[1], &byte, byte.len, 0));
        _ = c.close(fds[1]);
        _ = c.close(sibling_fds[1]);
    }
}

test "partial observer in a mixed controller connection is not a fail-close victim" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    _ = try registry_value.register(0xBB, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        83,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\"}",
    );
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"controller\"}}",
    );
    client.readReady(2);
    try sendTestFrame(
        fds[1],
        .request,
        3,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"bb\",\"mode\":\"observer\"}}",
    );
    client.readReady(3);
    const slot = try reactor.get(client.admission);
    try slot.consumeWritten(slot.pending_bytes);
    const observer = client.trackers.get(2).?;
    try slot.enqueueScreen(observer, "partial-observer");
    try slot.consumeWritten(1);
    slot.notePartial(.write, 10, false);

    try testing.expect(client.largestScreenPressure() == null);
    try testing.expect(registry.Capability.has(
        registry_value.capabilitiesOfSubscription(
            0xAA,
            client.connection.attachments.get(1).?.subscription_id,
        ),
        registry.Capability.input,
    ));
    try testing.expect(!client.isClosing());
}

test "failed recovery backoff does not pin round robin ahead of healthy siblings" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    inline for (.{ 0xAA, 0xBB, 0xCC }) |id| _ = try registry_value.register(id, 80, 24);
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        82,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"gui\",\"capabilities\":[\"runtime_metadata_v1\"],\"screen_stream_version\":2}",
    );
    client.readReady(1);
    inline for (.{ "aa", "bb", "cc" }, 0..) |id, index| {
        var params: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &params,
            "{{\"method\":\"runtime.attach\",\"params\":{{\"runtime_id\":\"{s}\",\"mode\":\"observer\"}}}}",
            .{id},
        );
        try sendTestFrame(fds[1], .request, 2 + index, request);
        client.readReady(2 + index);
    }
    const slot = try reactor.get(client.admission);
    try slot.consumeWritten(slot.pending_bytes);
    const recovering = client.trackers.get(2).?;
    client.invalidateSubscriptionOutput(2, recovering);
    try sendTestStreamFrame(fds[1], .stream_ack, 2, "{\"action\":\"resync\"}");
    client.readReady(10);

    runtime_ops.observation_fail_count = 1;
    runtime_ops.snapshot_fail_count = 1;
    const preflight_blocked_at = 10 + slot_mod.resync_retry_backoff_ns;
    const injected_pressure = slot_mod.shared_steady_bytes -
        reactor.budget.shared_bytes -
        slot_mod.base_update_max_bytes -
        slot_mod.resync_batch_bytes +
        1;
    reactor.budget.resident_bytes += injected_pressure;
    reactor.budget.shared_bytes += injected_pressure;
    _ = client.beginProducerSweep(preflight_blocked_at);
    client.tick(preflight_blocked_at);
    try testing.expectEqual(@as(usize, 3), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqualStrings(
        "NEW-BASE",
        client.connection.attachments.get(1).?.base.?,
    );
    try testing.expectEqual(@as(usize, 1), runtime_ops.delta_calls);
    reactor.budget.resident_bytes -= injected_pressure;
    reactor.budget.shared_bytes -= injected_pressure;

    const revision_before_failure =
        client.connection.attachments.get(2).?.observation_revision;
    const observation_failure_at = preflight_blocked_at + 1;
    _ = client.beginProducerSweep(observation_failure_at);
    client.tick(observation_failure_at);
    try testing.expectEqual(@as(usize, 3), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqual(
        revision_before_failure,
        client.connection.attachments.get(2).?.observation_revision,
    );
    try testing.expectEqual(
        @as(?[]u8, null),
        client.connection.attachments.get(2).?.observation_base,
    );

    const first_attempt = observation_failure_at + slot_mod.resync_retry_backoff_ns;
    _ = client.beginProducerSweep(first_attempt);
    client.tick(first_attempt);
    try testing.expectEqual(@as(usize, 4), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqual(
        @as(usize, 0),
        try slot.preparedBaseBytes(recovering),
    );
    try testing.expectEqual(@as(usize, 0), try slot.retainedBaseBytes(recovering));
    try testing.expectEqual(@as(usize, 0), try slot.screenResidentBytes(recovering));
    try testing.expectEqual(
        revision_before_failure,
        client.connection.attachments.get(2).?.observation_revision,
    );
    try testing.expectEqual(
        @as(?[]u8, null),
        client.connection.attachments.get(2).?.observation_base,
    );
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_base_bytes);
    try testing.expectEqual(@as(usize, 0), reactor.budget.prepared_reclaim_bytes);
    try testing.expectEqualStrings("NEW-BASE", client.connection.attachments.get(1).?.base.?);
    try testing.expectEqualStrings("SNAPSHOT-BYTES", client.connection.attachments.get(3).?.base.?);

    // Stream 2 is now inside the one-second backoff. Priority selection must not rewind the
    // cursor, so stream 3 and then stream 1 each get a normal producer turn.
    client.tick(first_attempt + 1);
    try testing.expectEqualStrings("NEW-BASE", client.connection.attachments.get(3).?.base.?);
    try testing.expectEqual(@as(usize, 2), runtime_ops.delta_calls);
    client.tick(first_attempt + 2);
    try testing.expectEqualStrings("NEW-BASE", client.connection.attachments.get(1).?.base.?);
    try testing.expectEqual(@as(usize, 3), runtime_ops.delta_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    try testing.expect(!client.connection.attachments.get(2).?.awaiting_resync_ack);
    var notices_after_failure: usize = 0;
    for (0..slot.chunk_len) |logical| {
        const chunk = slot.chunks[(slot.chunk_head + logical) % slot_mod.max_chunks_per_slot];
        if (chunk.class == .control and
            std.mem.indexOf(u8, chunk.bytes, "snapshot.invalidated") != null)
            notices_after_failure += 1;
    }
    try testing.expectEqual(@as(usize, 1), notices_after_failure);

    const retry_at = first_attempt + slot_mod.resync_retry_backoff_ns;
    _ = client.beginProducerSweep(retry_at - 1);
    client.tick(retry_at - 1);
    try testing.expectEqual(@as(usize, 4), runtime_ops.snapshot_calls);
    try testing.expect(client.connection.attachments.get(2).?.resync_pending);
    _ = client.beginProducerSweep(retry_at);
    client.tick(retry_at);
    try testing.expectEqual(@as(usize, 5), runtime_ops.snapshot_calls);
    try testing.expect(!client.connection.attachments.get(2).?.resync_pending);
    try testing.expectEqual(
        slot_mod.ScreenState.resync_draining,
        try slot.screenState(recovering),
    );
}

test "pressure after a written screen prefix fail closes instead of splicing the wire" {
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
    var runtime_ops: server.FakeRuntimeOps = .{};
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        83,
        &registry_value,
        &subscriptions,
        .{ .runtime_ops = runtime_ops.ops() },
    );
    defer client.destroy();
    try sendTestFrame(fds[1], .hello, 1, test_hello);
    client.readReady(1);
    try sendTestFrame(
        fds[1],
        .request,
        2,
        "{\"method\":\"runtime.attach\",\"params\":{\"runtime_id\":\"aa\",\"mode\":\"observer\"}}",
    );
    client.readReady(2);
    const slot = try reactor.get(client.admission);
    try slot.consumeWritten(slot.pending_bytes);
    const tracker = client.trackers.get(1).?;
    try slot.enqueueScreen(tracker, "written-prefix");
    try testing.expectEqual(slot_mod.QueueClass.screen, slot.firstPending().?.class);
    try slot.consumeWritten(1);

    const megabyte = try testing.allocator.alloc(u8, protocol.max_binary_chunk);
    defer testing.allocator.free(megabyte);
    @memset(megabyte, 'q');
    for (0..7) |_| try slot.enqueueScreen(tracker, megabyte);
    const batch = try testing.allocator.alloc([]u8, 1);
    batch[0] = try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
        megabyte,
    );
    try testing.expect(!client.adoptSubscriptionTurn(1, batch));
    try testing.expect(client.isClosing());
}

test "subscription batch preflight rejects cross-stream mixed and unterminated output" {
    const testing = std.testing;
    const valid = [_][]u8{
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .event, .stream_id = 1 },
            "{\"event\":\"runtime.metadata\"}",
        ),
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .snapshot_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
            "snapshot",
        ),
    };
    defer for (valid) |frame| testing.allocator.free(frame);
    try testing.expect(validateSubscriptionBatch(1, &valid));

    const cross = [_][]u8{try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .delta_chunk, .stream_id = 2, .flags = protocol.Flags.end_stream },
        "delta",
    )};
    defer testing.allocator.free(cross[0]);
    try testing.expect(!validateSubscriptionBatch(1, &cross));

    const unterminated = [_][]u8{try framing.encodeFrame(
        testing.allocator,
        .{ .kind = .snapshot_chunk, .stream_id = 1 },
        "snapshot",
    )};
    defer testing.allocator.free(unterminated[0]);
    try testing.expect(!validateSubscriptionBatch(1, &unterminated));

    const mixed = [_][]u8{
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .snapshot_chunk, .stream_id = 1 },
            "a",
        ),
        try framing.encodeFrame(
            testing.allocator,
            .{ .kind = .delta_chunk, .stream_id = 1, .flags = protocol.Flags.end_stream },
            "b",
        ),
    };
    defer for (mixed) |frame| testing.allocator.free(frame);
    try testing.expect(!validateSubscriptionBatch(1, &mixed));
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

test "one-shot admin leaves a pipelined second request undispatched" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    var admin_admission: server.AdminAdmission = .{};
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        9,
        &registry_value,
        &subscriptions,
        .{ .admin_admission = &admin_admission },
    );
    defer client.destroy();

    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try testing.expect(admin_admission.active);

    try sendTestFrame(fds[1], .ping, 2, "admin-ping");
    try sendTestFrame(fds[1], .request, 3, "{\"method\":\"host.info\"}");
    client.readReady(3);
    try testing.expect(client.close_after_flush != null);
    try testing.expect(client.admin_request_deadline_at_ns == null);
    client.tick(3 +| admin_request_deadline_ns);
    try testing.expect(!client.isClosing());
    try testing.expect(client.hasBufferedReadWork() == false);
    client.writeReady(4);
    try testing.expect(client.isClosing());

    var parser = framing.FrameParser.init(testing.allocator);
    defer parser.deinit();
    var bytes: [4096]u8 = undefined;
    const rc = c.recv(fds[1], &bytes, bytes.len, 0);
    try testing.expect(rc > 0);
    try parser.push(bytes[0..@intCast(rc)]);
    var responses: usize = 0;
    while (try parser.next()) |frame| {
        defer frame.deinit(testing.allocator);
        try testing.expectEqual(@as(u64, 2), frame.header.request_id);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "unauthorized") != null);
        responses += 1;
    }
    try testing.expectEqual(@as(usize, 1), responses);
}

test "admin runtime end mutates only after reply queue admission and then flushes before close" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    _ = try registry_value.register(0xAA, 80, 24);
    var runtime_ops: server.FakeRuntimeOps = .{};
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var admin_admission: server.AdminAdmission = .{};
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            9,
            &registry_value,
            &subscriptions,
            .{ .admin_admission = &admin_admission, .runtime_ops = runtime_ops.ops() },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            1,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
        );
        client.readReady(1);
        client.writeReady(2);
        _ = drainNonblocking(fds[1]);
        client.control_admission_fail_once = true;
        try sendTestFrame(
            fds[1],
            .request,
            2,
            "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"aa\"}}",
        );
        client.readReady(3);
        try testing.expectEqual(@as(u128, 0), runtime_ops.terminated_id);
    }

    {
        var fds: [2]c_int = undefined;
        try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
        defer _ = c.close(fds[1]);
        var admin_admission: server.AdminAdmission = .{};
        const client = try Client.create(
            testing.allocator,
            fds[0],
            reactor,
            9,
            &registry_value,
            &subscriptions,
            .{ .admin_admission = &admin_admission, .runtime_ops = runtime_ops.ops() },
        );
        defer client.destroy();
        try sendTestFrame(
            fds[1],
            .hello,
            3,
            "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
        );
        client.readReady(4);
        client.writeReady(5);
        _ = drainNonblocking(fds[1]);
        try sendTestFrame(
            fds[1],
            .request,
            4,
            "{\"method\":\"runtime.terminate\",\"params\":{\"runtime_id\":\"aa\"}}",
        );
        client.readReady(6);
        try testing.expectEqual(@as(u128, 0xAA), runtime_ops.terminated_id);
        try testing.expect(client.close_after_flush != null);
        try testing.expect(!client.isClosing());
        client.writeReady(7);
        try testing.expect(client.isClosing());
        var response: [4096]u8 = undefined;
        const count = c.recv(fds[1], &response, response.len, 0);
        try testing.expect(count > 0);
        try testing.expect(std.mem.indexOf(u8, response[0..@intCast(count)], "\"terminated\":true") != null);
    }
}

test "admin request deadline is immutable under incomplete-byte drip" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    var fds: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds));
    defer _ = c.close(fds[1]);
    var registry_value = registry.TerminalRuntimeRegistry.init(testing.allocator);
    defer registry_value.deinit();
    var subscriptions = subscription_identity.Table.init(testing.allocator);
    defer subscriptions.deinit();
    var admin_admission: server.AdminAdmission = .{};
    const reactor = try slot_mod.ReactorCore.create(testing.allocator);
    defer reactor.destroy();
    const client = try Client.create(
        testing.allocator,
        fds[0],
        reactor,
        9,
        &registry_value,
        &subscriptions,
        .{ .admin_admission = &admin_admission },
    );
    defer client.destroy();

    try sendTestFrame(
        fds[1],
        .hello,
        1,
        "{\"protocol_min\":2,\"protocol_max\":2,\"client_kind\":\"admin\"}",
    );
    client.readReady(1);
    client.writeReady(2);
    _ = drainNonblocking(fds[1]);
    try testing.expectEqual(@as(?u64, 1 + admin_request_deadline_ns), client.admin_request_deadline_at_ns);

    const partial = [_]u8{'M'};
    try testing.expectEqual(@as(isize, 1), c.send(fds[1], &partial, partial.len, 0));
    client.readReady(admin_request_deadline_ns);
    try testing.expect(!client.isClosing());
    client.tick(1 + admin_request_deadline_ns);
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
