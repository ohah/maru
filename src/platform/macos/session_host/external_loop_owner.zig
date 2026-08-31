//! P5c3c-3b final-address owner for the interactive external attach loop.
//!
//! Tests are written before the owner so this slice cannot accidentally claim composition from
//! the already-complete 3a2 pre-raw owner alone.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const external_attach = @import("external_attach.zig");
const external_detach_chord = @import("external_detach_chord.zig");
const external_pump_owner = @import("external_pump_owner.zig");
const external_resize = @import("external_resize.zig");
const external_stdout_progress = @import("external_stdout_progress.zig");
const external_loop_policy = @import("external_loop_policy.zig");
const external_tty = @import("external_tty.zig");
const client_pump = @import("client_pump.zig");
const client_poison = @import("client_poison.zig");
const protocol = @import("protocol.zig");

extern "c" fn openpty(
    amaster: *c.fd_t,
    aslave: *c.fd_t,
    name: ?[*]u8,
    termp: ?*const posix.termios,
    winp: ?*const posix.winsize,
) c_int;
extern "c" fn usleep(useconds: c_uint) c_int;

pub const InitialRole = enum { observer, controller };
pub const InitError = error{InvalidSize};

/// Allocation-free local state initialized before raw mode. Both reducers receive the same closed
/// role value so observer input suppression and resize suppression cannot drift independently.
pub const IntegratedLocalState = struct {
    role: InitialRole,
    chord: external_detach_chord.Reducer,
    resize: external_resize.ExternalResizeState,
    terminal_size: external_tty.Size,

    pub fn init(role: InitialRole, size: external_tty.Size) InitError!IntegratedLocalState {
        if (size.cols == 0 or size.rows == 0) return error.InvalidSize;
        return .{
            .role = role,
            .chord = external_detach_chord.Reducer.init(switch (role) {
                .controller => .controller,
                .observer => .observer,
            }),
            .resize = external_resize.ExternalResizeState.init(size, switch (role) {
                .controller => .controller,
                .observer => .observer,
            }),
            .terminal_size = size,
        };
    }

    pub fn feedInput(
        self: *IntegratedLocalState,
        byte: u8,
        now_ns: i128,
    ) external_detach_chord.Error!external_detach_chord.Decision {
        return self.chord.feed(byte, now_ns);
    }
};

const Lifecycle = enum { empty, preparing, prepared, live, tearing_down, dead };

const CleanupState = struct {
    cause: external_loop_policy.CleanupCause,
    plan: external_loop_policy.CleanupPlan,
    signal: ?posix.SIG = null,
};

pub const PrepareError = external_pump_owner.PreRawPrepareError || error{
    InvalidSize,
};

/// Final-address aggregate consumed by the public attach loop.
///
/// `PreRawOwner` retains sole ownership of TTY/output/pump resources. This outer owner adds only
/// loop semantics and therefore never reaches through to raw `Client` storage.
pub const IntegratedStackOwner = struct {
    saved_self_addr: usize = 0,
    lifecycle: Lifecycle = .empty,
    pre_raw: external_pump_owner.PreRawOwner = .{},
    local: IntegratedLocalState = undefined,
    stdout_progress: ?external_stdout_progress.Progress = null,
    socket_write_interest: bool = false,
    /// A pump turn can publish owner-local work after consuming the last kernel readiness edge.
    /// Preserve that exact result until the next pump revalidates and clears it; `pollHint()` owns
    /// protocol deadlines/TX, while this latch owns the cross-turn scheduler handoff.
    host_immediate_interest: bool = false,
    stdin_interest: bool = true,
    pending_resize: bool = false,
    pending_resize_request: ?external_resize.Request = null,
    stdin_buffer: [external_loop_policy.stdin_budget_bytes]u8 = undefined,
    stdin_head: usize = 0,
    stdin_len: usize = 0,
    pending_forward: [2]u8 = undefined,
    pending_forward_len: u2 = 0,
    cleanup: ?CleanupState = null,

    pub fn prepareInPlace(
        self: *IntegratedStackOwner,
        prepared: *external_attach.Prepared,
        allocator: std.mem.Allocator,
        io: std.Io,
        stdin_fd: c.fd_t,
        stdout_fd: c.fd_t,
    ) PrepareError!void {
        if (self.saved_self_addr != 0 or self.lifecycle != .empty)
            return error.DestinationNotEmpty;
        self.saved_self_addr = @intFromPtr(self);
        self.lifecycle = .preparing;
        const role: InitialRole = switch (prepared.attachment.state.role) {
            .controller => .controller,
            .observer => .observer,
        };
        self.pre_raw.prepareInPlace(
            prepared,
            allocator,
            io,
            stdin_fd,
            stdout_fd,
        ) catch |err| {
            self.lifecycle = .tearing_down;
            self.settleFailedPreparation();
            return err;
        };
        self.local = IntegratedLocalState.init(role, self.pre_raw.inspection.initial_size) catch |err| {
            self.lifecycle = .tearing_down;
            self.settleFailedPreparation();
            return err;
        };
        self.pending_resize_request = self.local.resize.attached() catch {
            self.lifecycle = .tearing_down;
            self.settleFailedPreparation();
            return error.InvalidSize;
        };
        self.pending_resize = self.pending_resize_request != null;
        self.lifecycle = .prepared;
    }

    pub fn commit(self: *IntegratedStackOwner) external_pump_owner.PreRawCommitError!void {
        try self.requireLifecycle(.prepared);
        self.pre_raw.commit() catch |err| {
            self.lifecycle = .tearing_down;
            return err;
        };
        self.lifecycle = .live;
    }

    pub fn pollSet(
        self: *IntegratedStackOwner,
    ) external_pump_owner.PreRawCommitError!*[4]posix.pollfd {
        try self.requireLifecycle(.live);
        return self.pre_raw.pollSet();
    }

    pub const PollPlanError = error{
        Moved,
        InvalidLifecycle,
        InvalidClock,
        InvalidDeadline,
        DeadlineOverflow,
    };

    pub fn refreshPollInterests(self: *IntegratedStackOwner) PollPlanError!void {
        if (self.saved_self_addr != @intFromPtr(self)) return error.Moved;
        if (self.lifecycle != .live) return error.InvalidLifecycle;
        self.pre_raw.poll_fds[0].events = if (self.stdin_interest)
            posix.POLL.IN
        else
            @as(i16, 0);
        self.pre_raw.poll_fds[1].events = posix.POLL.IN |
            (if (self.socket_write_interest) posix.POLL.OUT else @as(i16, 0));
        self.pre_raw.poll_fds[2].events = if (self.pre_raw.repaint.current != null)
            posix.POLL.OUT
        else
            @as(i16, 0);
        self.pre_raw.poll_fds[3].events = posix.POLL.IN;
    }

    pub fn pollTimeoutMs(
        self: *IntegratedStackOwner,
        now_ns: i128,
        cleanup_deadline_ns: ?i128,
    ) PollPlanError!c_int {
        if (self.saved_self_addr != @intFromPtr(self)) return error.Moved;
        if (self.lifecycle != .live) return error.InvalidLifecycle;
        const chord_deadline = self.local.chord.nextDeadline() catch
            return error.DeadlineOverflow;
        const pump_hint = switch (self.pre_raw.pump.pollHint()) {
            .hint => |hint| hint,
            .moved_or_stale => return error.Moved,
        };
        const stdout_deadline = if (self.stdout_progress) |progress|
            progress.deadline() catch return error.DeadlineOverflow
        else
            null;
        const timeout = external_loop_policy.pollTimeoutMs(now_ns, .{
            .chord_ns = chord_deadline,
            .control_ns = pump_hint.next_deadline_ns,
            .io_ns = stdout_deadline,
            .cleanup_ns = cleanup_deadline_ns,
        }) catch |err| return switch (err) {
            error.InvalidClock => error.InvalidClock,
            error.InvalidDeadline => error.InvalidDeadline,
        };
        // A semantic self-wake still takes one kernel snapshot so revoke/signal/stdin readiness
        // cannot be starved, but that snapshot must never sleep behind owner-local work.
        return applyImmediatePollWake(
            timeout,
            self.host_immediate_interest,
            pump_hint.immediate,
        );
    }

    pub const CleanupWireResult = union(enum) {
        authority: external_loop_policy.WireAuthority,
        busy,
        terminal: client_pump.TerminalReason,
        invalid,
    };

    pub fn projectCleanupWireAuthority(self: *IntegratedStackOwner) CleanupWireResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .invalid;
        return switch (self.pre_raw.pump.projectCleanupWireAuthority()) {
            .authority => |authority| .{ .authority = switch (authority) {
                .none => .none,
                .offset_zero => .offset_zero,
                .control_in_flight => .control_in_flight,
                .partial_frame => .partial_frame,
                .response_wait => .response_wait,
            } },
            .busy => .busy,
            .terminal => |reason| .{ .terminal = reason },
            .invalid => .invalid,
        };
    }

    pub fn cancelOffsetZeroInputForCleanup(
        self: *IntegratedStackOwner,
        now_ns: i128,
    ) external_pump_owner.CleanupCancelResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .invalid;
        const result = self.pre_raw.pump.cancelOffsetZeroInputForCleanup(now_ns);
        if (result == .cancelled) self.socket_write_interest = false;
        return result;
    }

    pub fn nextAction(
        self: *IntegratedStackOwner,
        now_ns: i128,
    ) PollPlanError!external_loop_policy.Action {
        if (self.saved_self_addr != @intFromPtr(self)) return error.Moved;
        if (self.lifecycle != .live) return error.InvalidLifecycle;
        if (now_ns < 0) return error.InvalidClock;
        const fds = &self.pre_raw.poll_fds;
        const chord_deadline = self.local.chord.nextDeadline() catch
            return error.DeadlineOverflow;
        const pump_hint = switch (self.pre_raw.pump.pollHint()) {
            .hint => |hint| hint,
            .moved_or_stale => return error.Moved,
        };
        return external_loop_policy.selectAction(.{
            .termination_signal = pollInputOrTerminal(fds[3].revents),
            .host_rx = pollInputOrTerminal(fds[1].revents),
            .chord_deadline = if (chord_deadline) |deadline| now_ns >= deadline else false,
            .socket_tx = self.socket_write_interest and
                fds[1].revents & posix.POLL.OUT != 0,
            .host_immediate = self.host_immediate_interest or pump_hint.immediate,
            .stdout_tx = self.pre_raw.repaint.current != null and
                fds[2].revents & posix.POLL.OUT != 0,
            .resize = self.pending_resize,
            .retained_stdin = self.pending_forward_len != 0 or
                self.stdin_head != self.stdin_len,
            .stdin_rx = self.stdin_interest and fds[0].revents & posix.POLL.IN != 0,
        });
    }

    pub const ActionExecution = union(enum) {
        idle,
        signal: SignalResult,
        pump: client_pump.TurnResult,
        host_immediate: client_pump.TurnResult,
        chord: InputResult,
        stdout: StdoutResult,
        resize: ResizeResult,
        stdin: StdinResult,
    };

    /// Executes exactly one highest-priority action. The caller refreshes the monotonic clock and
    /// re-enters before any lower-priority work, preserving the SSOT revalidation boundary.
    pub fn executeReadyAction(
        self: *IntegratedStackOwner,
        now_ns: i128,
        io: std.Io,
    ) PollPlanError!ActionExecution {
        const action = try self.nextAction(now_ns);
        self.consumePolledReadiness(action);
        return switch (action) {
            .termination_signal => .{ .signal = self.drainSignalWake() },
            .host_rx => .{ .pump = self.executePumpAction(.{
                .readable = true,
                .writable = self.pre_raw.poll_fds[1].revents & posix.POLL.OUT != 0,
                .now_ns = now_ns,
            }, io) },
            .chord_deadline => blk: {
                const decision = self.local.chord.expire(now_ns) catch
                    break :blk .{ .chord = .{ .terminal = .invariant_failure } };
                const value = decision orelse break :blk .idle;
                if (value.suppressed) break :blk .{ .chord = .suppressed };
                const bytes = value.bytes();
                if (bytes.len == 0) break :blk .idle;
                const result = self.admitAuthorizedInput(bytes, now_ns);
                switch (result) {
                    .backpressure, .busy => {
                        @memcpy(self.pending_forward[0..bytes.len], bytes);
                        self.pending_forward_len = @intCast(bytes.len);
                    },
                    else => {},
                }
                break :blk .{ .chord = result };
            },
            // A writable action still runs the mandatory zero-readiness RX prefix before TX.
            .socket_tx => .{ .pump = self.executePumpAction(.{
                .readable = true,
                .writable = true,
                .now_ns = now_ns,
            }, io) },
            .host_immediate => .{ .host_immediate = self.executePumpAction(.{
                .readable = true,
                .writable = false,
                .now_ns = now_ns,
            }, io) },
            .stdout_tx => .{ .stdout = self.flushStdout(now_ns) },
            .resize => .{ .resize = self.applyPendingResize(now_ns) },
            .stdin_rx => .{ .stdin = self.drainStdin(now_ns) },
            .poll_wait => .idle,
        };
    }

    /// `revents` describes one poll snapshot. Once its selected action has drained the bounded
    /// owner, retaining that bit would replay stale readiness and starve every lower-priority
    /// source. Socket RX consumes the same turn's writable suffix, so it retires the whole socket
    /// snapshot; a TX-only turn retires only POLLOUT.
    fn consumePolledReadiness(
        self: *IntegratedStackOwner,
        action: external_loop_policy.Action,
    ) void {
        switch (action) {
            .termination_signal => self.pre_raw.poll_fds[3].revents = 0,
            .host_rx => self.pre_raw.poll_fds[1].revents = 0,
            .socket_tx => self.pre_raw.poll_fds[1].revents &=
                ~@as(i16, posix.POLL.OUT),
            .host_immediate => {},
            .stdout_tx => self.pre_raw.poll_fds[2].revents = 0,
            .stdin_rx => self.pre_raw.poll_fds[0].revents = 0,
            .chord_deadline, .resize, .poll_wait => {},
        }
    }

    fn executePumpAction(
        self: *IntegratedStackOwner,
        turn: client_pump.TurnInput,
        io: std.Io,
    ) client_pump.TurnResult {
        // `pumpHost` owns poll-interest publication for both direct callers and loop actions.
        return self.pumpHost(turn, io);
    }

    pub fn notePumpResult(self: *IntegratedStackOwner, result: client_pump.TurnResult) void {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live) return;
        if (result.terminal != null) {
            self.socket_write_interest = false;
            self.host_immediate_interest = false;
            self.stdin_interest = false;
            return;
        }
        self.host_immediate_interest = result.inherited_work_ready or
            result.immediate_rx;
        // `write_interest=false` is authoritative only after the pump proved the RX/control
        // frontier clear. While inherited screen/metadata work blocks that proof, clearing an
        // already-armed POLLOUT loses the only wake for an admitted input frame. Preserve the
        // prior interest until a clear turn can inspect the actual TX queue.
        if (result.authority_clear)
            self.socket_write_interest = result.write_interest or result.immediate_tx
        else if (result.immediate_tx)
            self.socket_write_interest = true;
    }

    pub const SignalResult = union(enum) {
        idle,
        resize_pending,
        terminate: posix.SIG,
        terminal: client_pump.TerminalReason,
    };

    pub fn drainSignalWake(self: *IntegratedStackOwner) SignalResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        const raw = if (self.pre_raw.raw) |*value| value else return .{ .terminal = .invariant_failure };
        const batch = raw.drainWakeBatch() catch
            return .{ .terminal = .invariant_failure };
        if (batch.termination) |signal| {
            self.stdin_interest = false;
            self.pending_resize = false;
            self.pending_resize_request = null;
            return .{ .terminate = signal };
        }
        if (batch.resize) {
            self.pending_resize = true;
            return .resize_pending;
        }
        return .idle;
    }

    pub const ResizeResult = union(enum) {
        idle,
        suppressed,
        admitted,
        backpressure,
        busy,
        terminal: client_pump.TerminalReason,
    };

    pub fn applyPendingResize(self: *IntegratedStackOwner, now_ns: i128) ResizeResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        if (!self.pending_resize) return .idle;
        const raw = if (self.pre_raw.raw) |*value| value else return .{ .terminal = .invariant_failure };
        const size = raw.currentSize() catch return .{ .terminal = .invariant_failure };
        self.local.terminal_size = size;
        if (self.pending_resize_request) |*pending| {
            pending.size = size;
        } else {
            const request = self.local.resize.localResize(size) catch
                return .{ .terminal = .resource_exhausted };
            self.pending_resize_request = request orelse {
                self.pending_resize = false;
                return if (self.local.role == .observer) .suppressed else .idle;
            };
        }
        const value = self.pending_resize_request.?;
        const admission = self.pre_raw.pump.admitControl(.{
            .request = .{ .resize = .{
                .stream_id = self.pre_raw.pump.attachment.state.stream_id,
                .cols = value.size.cols,
                .rows = value.size.rows,
                .client_sequence = value.client_sequence,
            } },
            .expected_controller_generation = self.pre_raw.pump.attachment.state.controller_generation,
        }, now_ns);
        return switch (admission) {
            .admitted => result: {
                self.pending_resize = false;
                self.pending_resize_request = null;
                self.local.resize.last_sent_size = value.size;
                self.socket_write_interest = true;
                break :result .admitted;
            },
            .backpressure => .backpressure,
            .busy => .busy,
            .terminal => |reason| .{ .terminal = reason },
        };
    }

    pub const InputResult = union(enum) {
        waiting_chord,
        detached,
        suppressed,
        admitted: usize,
        backpressure,
        busy,
        terminal: client_pump.TerminalReason,
    };

    /// Applies the local chord/observer policy before the only external-pump TX admission port.
    /// A controller decision forwards at most two bytes; observer bytes never reach the host.
    pub fn admitInputByte(
        self: *IntegratedStackOwner,
        byte: u8,
        now_ns: i128,
    ) InputResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        const decision = self.local.feedInput(byte, now_ns) catch
            return .{ .terminal = .invariant_failure };
        if (decision.detached) return .detached;
        if (decision.suppressed) return .suppressed;
        const bytes = decision.bytes();
        if (bytes.len == 0) return .waiting_chord;
        return self.admitAuthorizedInput(bytes, now_ns);
    }

    fn admitAuthorizedInput(
        self: *IntegratedStackOwner,
        bytes: []const u8,
        now_ns: i128,
    ) InputResult {
        return switch (self.pre_raw.pump.admitTx(.{
            .kind = protocol.Kind.input_bytes,
            .stream_id = self.pre_raw.pump.attachment.state.stream_id,
            .payload = bytes,
            .request_policy = .zero,
        }, now_ns)) {
            .admitted => result: {
                // Admission only publishes an immutable queue item. The integrated loop owns the
                // poll interest that makes that item writable, so it must arm POLLOUT in the same
                // suffix or freshly admitted input can sleep forever without another wake source.
                self.socket_write_interest = true;
                break :result .{ .admitted = bytes.len };
            },
            .backpressure => .backpressure,
            .busy => .busy,
            .terminal => |reason| .{ .terminal = reason },
        };
    }

    pub const StdinResult = union(enum) {
        idle,
        progressed: struct {
            bytes_read: usize,
            bytes_admitted: usize,
            bytes_suppressed: usize,
        },
        blocked,
        detached,
        eof,
        terminal: client_pump.TerminalReason,
    };

    /// Drains at most one 64 KiB stdin turn and retains both unread input and a chord-authorized
    /// two-byte forwarding decision across TX backpressure. No byte is re-fed through the chord
    /// reducer after it has mutated state.
    pub fn drainStdin(self: *IntegratedStackOwner, now_ns: i128) StdinResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        var bytes_read: usize = 0;
        var bytes_admitted: usize = 0;
        var bytes_suppressed: usize = 0;
        if (self.stdin_head == self.stdin_len and self.pending_forward_len == 0) {
            self.stdin_head = 0;
            self.stdin_len = 0;
            const fd = self.pre_raw.poll_fds[0].fd;
            const count = c.read(fd, &self.stdin_buffer, self.stdin_buffer.len);
            if (count == 0) {
                self.local.chord.inputEof();
                self.stdin_interest = false;
                return .eof;
            }
            if (count < 0) return switch (posix.errno(count)) {
                .INTR, .AGAIN => .idle,
                else => .{ .terminal = .socket_error },
            };
            self.stdin_len = @intCast(count);
            bytes_read = self.stdin_len;
        }
        while (true) {
            if (self.pending_forward_len != 0) {
                const forward = self.pending_forward[0..self.pending_forward_len];
                switch (self.admitAuthorizedInput(forward, now_ns)) {
                    .admitted => |count| {
                        bytes_admitted += count;
                        self.pending_forward_len = 0;
                    },
                    .backpressure, .busy => return if (bytes_read == 0 and
                        bytes_admitted == 0 and bytes_suppressed == 0)
                        .blocked
                    else
                        .{ .progressed = .{
                            .bytes_read = bytes_read,
                            .bytes_admitted = bytes_admitted,
                            .bytes_suppressed = bytes_suppressed,
                        } },
                    .terminal => |reason| return .{ .terminal = reason },
                    .waiting_chord, .detached, .suppressed => return .{ .terminal = .invariant_failure },
                }
                continue;
            }
            if (self.stdin_head == self.stdin_len) {
                self.stdin_head = 0;
                self.stdin_len = 0;
                return if (bytes_read == 0 and bytes_admitted == 0 and bytes_suppressed == 0)
                    .idle
                else
                    .{ .progressed = .{
                        .bytes_read = bytes_read,
                        .bytes_admitted = bytes_admitted,
                        .bytes_suppressed = bytes_suppressed,
                    } };
            }
            const byte = self.stdin_buffer[self.stdin_head];
            self.stdin_head += 1;
            const decision = self.local.feedInput(byte, now_ns) catch
                return .{ .terminal = .invariant_failure };
            if (decision.detached) {
                self.stdin_head = 0;
                self.stdin_len = 0;
                self.pending_forward_len = 0;
                self.stdin_interest = false;
                return .detached;
            }
            if (decision.suppressed) {
                bytes_suppressed += 1;
                continue;
            }
            const forward = decision.bytes();
            if (forward.len == 0) continue;
            @memcpy(self.pending_forward[0..forward.len], forward);
            self.pending_forward_len = @intCast(forward.len);
        }
    }

    const ApplyContext = struct {
        owner: *IntegratedStackOwner,
        io: std.Io,
        failure: ?client_pump.TerminalReason = null,

        fn apply(
            raw: *anyopaque,
            view: external_pump_owner.LiveScreenPayloadView,
        ) external_pump_owner.LiveScreenApplyResult {
            const self: *ApplyContext = @ptrCast(@alignCast(raw));
            const screen = &(self.owner.pre_raw.pump.attachment.screen orelse {
                self.failure = .invariant_failure;
                return .applied;
            });
            self.owner.pre_raw.pump.attachment.applyExternalLiveScreen(view, self.io) catch |err| {
                self.failure = if (err == error.OutOfMemory)
                    .resource_exhausted
                else
                    .protocol_error;
                return .applied;
            };
            const sequence = self.owner.pre_raw.next_projection_sequence;
            if (sequence == std.math.maxInt(u64)) {
                self.failure = .resource_exhausted;
                return .applied;
            }
            self.owner.pre_raw.repaint.replaceLatest(
                screen.screenSource(),
                .{
                    .cols = self.owner.local.terminal_size.cols,
                    .rows = self.owner.local.terminal_size.rows,
                },
                self.io,
                sequence,
            ) catch |err| {
                self.failure = if (err == error.OutOfMemory)
                    .resource_exhausted
                else
                    .protocol_error;
                return .applied;
            };
            self.owner.pre_raw.next_projection_sequence = sequence + 1;
            return .applied;
        }
    };

    /// Runs the inherited Client RX/TX transaction and applies live screen batches through the
    /// already-owned `RemoteAttachment`. Any callback failure is latched only after the pump's
    /// whole-turn lease is released, then the socket is failed closed.
    pub fn pumpHost(
        self: *IntegratedStackOwner,
        turn: client_pump.TurnInput,
        io: std.Io,
    ) client_pump.TurnResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live) {
            return .{ .terminal = .{
                .reason = .invariant_failure,
                .fd_disposition = .owner_cleanup,
            } };
        }
        var context = ApplyContext{ .owner = self, .io = io };
        var result = self.pre_raw.pump.pumpApplying(
            turn,
            &context,
            @sizeOf(ApplyContext),
            ApplyContext.apply,
        );
        // Every live return path, including a committed-screen retry or terminal, publishes the
        // loop-owned poll interests exactly once.
        defer self.notePumpResult(result);
        if (result.terminal == null and result.inherited_work_ready) {
            // Live screen work is consumed by `pumpApplying`, while aggregate-committed screen
            // batches retain their existing charged `RemoteAttachment` lease path. Drain at most
            // one before metadata/resize so every inherited owner has one bounded scheduler.
            switch (self.pre_raw.pump.pumpCommittedScreen(io)) {
                .idle => {},
                .retry => return result,
                .terminal => |reason| {
                    result.terminal = .{
                        .reason = reason,
                        .fd_disposition = .owner_cleanup,
                    };
                    return result;
                },
                .applied => |source| {
                    const sequence = self.pre_raw.next_projection_sequence;
                    if (sequence == std.math.maxInt(u64)) {
                        result.terminal = .{
                            .reason = .resource_exhausted,
                            .fd_disposition = .owner_cleanup,
                        };
                        return result;
                    }
                    self.pre_raw.repaint.replaceLatest(
                        source,
                        .{
                            .cols = self.local.terminal_size.cols,
                            .rows = self.local.terminal_size.rows,
                        },
                        io,
                        sequence,
                    ) catch |err| {
                        result.terminal = .{
                            .reason = if (err == error.OutOfMemory)
                                .resource_exhausted
                            else
                                .protocol_error,
                            .fd_disposition = .owner_cleanup,
                        };
                        return result;
                    };
                    self.pre_raw.next_projection_sequence = sequence + 1;
                    return result;
                },
            }
            // Metadata/resize use the adjacent owner projection transaction.
            switch (self.pre_raw.pump.consumeCliOwnerProjection()) {
                .applied, .none, .retry => {},
                .terminal => result.terminal = .{
                    .reason = .invariant_failure,
                    .fd_disposition = .owner_cleanup,
                },
            }
        }
        if (context.failure) |reason| {
            self.pre_raw.pump.latchAttachmentFailure(switch (reason) {
                .resource_exhausted => client_poison.ConnectionReason.local_resource_exhausted,
                .protocol_error => .frame_malformed,
                else => .local_invariant_violation,
            });
            if (result.terminal == null) result.terminal = .{
                .reason = reason,
                .fd_disposition = .owner_cleanup,
            };
        }
        return result;
    }

    pub const StdoutResult = union(enum) {
        idle,
        blocked: usize,
        progressed: struct { bytes: usize, frame_complete: bool },
        terminal: client_pump.TerminalReason,
    };

    /// Flushes at most the normative 64 KiB stdout budget from one immutable current frame.
    /// Partial frames retain their exact offset and cannot be replaced by a newer repaint.
    pub fn flushStdout(self: *IntegratedStackOwner, now_ns: i128) StdoutResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .{ .terminal = .invariant_failure };
        const frame = if (self.pre_raw.repaint.current) |*value| value else return .idle;
        if (self.stdout_progress == null) {
            self.stdout_progress = external_stdout_progress.Progress.activate(
                frame.bytes.len,
                now_ns,
            ) catch return .{ .terminal = .invariant_failure };
        }
        const progress = &self.stdout_progress.?;
        if (progress.len != frame.bytes.len or progress.offset >= progress.len)
            return .{ .terminal = .invariant_failure };
        if (progress.expired(now_ns) catch true)
            return .{ .terminal = .deadline_exceeded };
        const fd = self.pre_raw.output.pollFd() catch
            return .{ .terminal = .invariant_failure };
        var written_total: usize = 0;
        var interrupts: u8 = 0;
        while (written_total < external_loop_policy.stdout_budget_bytes) {
            const remaining = progress.len - progress.offset;
            const allowance = @min(
                remaining,
                external_loop_policy.stdout_budget_bytes - written_total,
            );
            const count = c.write(fd, frame.bytes[progress.offset..][0..allowance].ptr, allowance);
            if (count > 0) {
                const amount: usize = @intCast(count);
                written_total += amount;
                const complete = progress.recordWrite(amount, now_ns) catch
                    return .{ .terminal = .invariant_failure };
                if (complete) {
                    self.pre_raw.repaint.completeCurrent();
                    self.stdout_progress = null;
                    return .{ .progressed = .{
                        .bytes = written_total,
                        .frame_complete = true,
                    } };
                }
                continue;
            }
            if (count < 0) switch (posix.errno(count)) {
                .INTR => {
                    interrupts += 1;
                    if (interrupts <= @import("client_pump.zig").max_interrupt_retries_per_direction)
                        continue;
                    return .{ .terminal = .socket_error };
                },
                .AGAIN => return if (written_total == 0)
                    .{ .blocked = 0 }
                else
                    .{ .progressed = .{ .bytes = written_total, .frame_complete = false } },
                else => return .{ .terminal = .socket_error },
            };
            return .{ .terminal = .socket_error };
        }
        return .{ .progressed = .{ .bytes = written_total, .frame_complete = false } };
    }

    pub const BeginCleanupResult = union(enum) {
        begun: external_loop_policy.CleanupPlan,
        busy,
        projection_terminal: client_pump.TerminalReason,
        detach_terminal: client_pump.TerminalReason,
        invalid,
    };

    /// Freezes every producer before deriving the cleanup plan from the pump's sealed wire view.
    /// The plan is stored once; later turns may drain work but can never relax it.
    pub fn beginCleanup(
        self: *IntegratedStackOwner,
        cause: external_loop_policy.CleanupCause,
        signal: ?posix.SIG,
        now_ns: i128,
    ) BeginCleanupResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .invalid;
        if (self.cleanup != null) return .busy;
        if ((cause == .signal) != (signal != null)) return .invalid;
        // Only an ordinary local detach may append wire and therefore needs the sealed queue
        // projection. Terminal pump states are expected on revoke/EOF/error cleanup; asking that
        // already-terminal owner for a live projection would make the required cleanup
        // unreachable.
        const wire: external_loop_policy.WireAuthority = if (cause == .local_detach)
            switch (self.projectCleanupWireAuthority()) {
                .authority => |authority| authority,
                .busy => return .busy,
                .terminal => |reason| return .{ .projection_terminal = reason },
                .invalid => return .invalid,
            }
        else
            .none;
        var plan = external_loop_policy.planCleanup(cause, wire, now_ns) catch
            return .invalid;

        self.stdin_interest = false;
        self.stdin_head = 0;
        self.stdin_len = 0;
        self.pending_forward_len = 0;
        self.pending_resize = false;
        self.pending_resize_request = null;
        if (plan.discard_active_repaint) self.discardRepaints();

        if (plan.cancel_zero_offset_tx and
            self.cancelOffsetZeroInputForCleanup(now_ns) != .cancelled)
        {
            plan.detach_allowed = false;
            plan.fail_close_socket = true;
            plan.detach_repaint_deadline_ns = null;
        }
        if (plan.detach_allowed) switch (self.pre_raw.pump.admitDetach(now_ns)) {
            .admitted => self.socket_write_interest = true,
            .backpressure, .busy => {
                plan.detach_allowed = false;
                plan.fail_close_socket = true;
                plan.detach_repaint_deadline_ns = null;
            },
            .terminal => |reason| return .{ .detach_terminal = reason },
        };
        self.cleanup = .{ .cause = cause, .plan = plan, .signal = signal };
        return .{ .begun = plan };
    }

    pub const DriveCleanupResult = union(enum) {
        pending: i128,
        cleaned: external_pump_owner.PreRawTeardownResult,
        invalid,
    };

    /// Performs one bounded cleanup turn. Normal detach and the active repaint share the first
    /// 100 ms; abnormal paths discard both and proceed directly to leave/raw restoration.
    pub fn driveCleanup(
        self: *IntegratedStackOwner,
        now_ns: i128,
        io: std.Io,
    ) DriveCleanupResult {
        if (self.saved_self_addr != @intFromPtr(self) or self.lifecycle != .live)
            return .invalid;
        const state = self.cleanup orelse return .invalid;
        if (now_ns < 0) return .invalid;

        if (state.plan.detach_repaint_deadline_ns) |prefix_deadline| {
            if (now_ns < prefix_deadline) {
                if (self.socket_write_interest) {
                    const turn = self.executePumpAction(.{
                        .readable = true,
                        .writable = true,
                        .now_ns = now_ns,
                    }, io);
                    if (turn.terminal != null) {
                        self.discardRepaints();
                        return .{ .cleaned = self.teardown() };
                    }
                }
                if (self.pre_raw.repaint.current != null) switch (self.flushStdout(now_ns)) {
                    .terminal => {
                        self.discardRepaints();
                        return .{ .cleaned = self.teardown() };
                    },
                    else => {},
                };
                const wire_clear = switch (self.projectCleanupWireAuthority()) {
                    .authority => |authority| authority == .none,
                    else => false,
                };
                if (wire_clear and self.pre_raw.repaint.current == null)
                    return .{ .cleaned = self.teardown() };
                return .{ .pending = prefix_deadline };
            }
            self.discardRepaints();
        }
        return .{ .cleaned = self.teardown() };
    }

    pub const RunResult = struct {
        cause: external_loop_policy.CleanupCause,
        terminal_reason: ?client_pump.TerminalReason = null,
        teardown: external_pump_owner.PreRawTeardownResult,
    };

    pub const RunError = error{
        Moved,
        InvalidLifecycle,
        ClockFailed,
        PollFailed,
        CleanupDriveInvalid,
        ReadyActionFailed,
        CleanupProjectionTerminal,
        CleanupDetachProtocolError,
        CleanupDetachInvariantFailure,
        CleanupDetachOtherTerminal,
        CleanupStartInvalid,
        PollPlanFailed,
    };

    /// Owns the actual POSIX poll loop after raw commit. Every action returns to the top for a
    /// fresh monotonic sample and priority decision, so a lower-priority ready bit cannot run on
    /// authority observed before a revoke, signal, or role transition.
    pub fn run(
        self: *IntegratedStackOwner,
        io: std.Io,
    ) RunError!RunResult {
        if (self.saved_self_addr != @intFromPtr(self)) return error.Moved;
        if (self.lifecycle != .live) return error.InvalidLifecycle;
        var terminal_reason: ?client_pump.TerminalReason = null;

        while (true) {
            const now_ns = monotonicNowNs() catch return self.failRun(error.ClockFailed);
            var force_nonblocking_snapshot = false;
            if (self.cleanup) |state| {
                const cleanup_result = self.driveCleanup(now_ns, io);
                switch (cleanup_result) {
                    .cleaned => |teardown_result| return .{
                        .cause = state.cause,
                        .terminal_reason = terminal_reason,
                        .teardown = teardown_result,
                    },
                    .pending => {},
                    .invalid => return self.failRun(error.CleanupDriveInvalid),
                }
            } else {
                const execution = self.executeReadyAction(now_ns, io) catch
                    return self.failRun(error.ReadyActionFailed);
                const cleanup_cause: ?external_loop_policy.CleanupCause = switch (execution) {
                    .idle => null,
                    .signal => |signal_result| switch (signal_result) {
                        .idle, .resize_pending => null,
                        .terminate => |signal| cause: {
                            switch (self.startCleanup(.signal, signal, now_ns)) {
                                .started => {},
                                .projection_terminal => return self.failRun(error.CleanupProjectionTerminal),
                                .detach_terminal => |reason| return self.failRun(detachTerminalError(reason)),
                                .invalid => return self.failRun(error.CleanupStartInvalid),
                            }
                            break :cause .signal;
                        },
                        .terminal => |reason| cause: {
                            terminal_reason = reason;
                            break :cause terminalCleanupCause(reason);
                        },
                    },
                    .pump, .host_immediate => |turn| if (turn.terminal) |terminal| cause: {
                        terminal_reason = terminal.reason;
                        break :cause terminalCleanupCause(terminal.reason);
                    } else null,
                    .chord => |result| switch (result) {
                        .detached => .local_detach,
                        .terminal => |reason| cause: {
                            terminal_reason = reason;
                            break :cause terminalCleanupCause(reason);
                        },
                        else => null,
                    },
                    .stdout => |result| switch (result) {
                        .terminal => |reason| cause: {
                            terminal_reason = reason;
                            break :cause terminalCleanupCause(reason);
                        },
                        else => null,
                    },
                    .resize => |result| switch (result) {
                        .terminal => |reason| cause: {
                            terminal_reason = reason;
                            break :cause terminalCleanupCause(reason);
                        },
                        else => null,
                    },
                    .stdin => |result| switch (result) {
                        .detached, .eof => .local_detach,
                        .terminal => |reason| cause: {
                            terminal_reason = reason;
                            break :cause terminalCleanupCause(reason);
                        },
                        else => null,
                    },
                };
                if (cleanup_cause) |cause| {
                    if (self.cleanup == null) switch (self.startCleanup(cause, null, now_ns)) {
                        .started => {},
                        .projection_terminal => return self.failRun(error.CleanupProjectionTerminal),
                        .detach_terminal => |reason| return self.failRun(detachTerminalError(reason)),
                        .invalid => return self.failRun(error.CleanupStartInvalid),
                    };
                    continue;
                }
                // A self-woken semantic suffix must not prevent the kernel poll snapshot from
                // observing a newly arrived detach chord, revoke, or termination signal. Its
                // immediate hint makes this poll nonblocking, preserving progress without a busy
                // loop that can starve external readiness forever.
                const execution_tag = std.meta.activeTag(execution);
                if (execution_tag != .idle and execution_tag != .host_immediate) continue;
                force_nonblocking_snapshot =
                    external_loop_policy.postImmediatePollMustBeNonblocking(
                        if (execution_tag == .host_immediate)
                            .host_immediate
                        else
                            .poll_wait,
                        .{
                            .resize = self.pending_resize,
                            .retained_stdin = self.pending_forward_len != 0 or
                                self.stdin_head != self.stdin_len,
                        },
                    );
            }

            self.refreshPollInterests() catch
                return self.failRun(error.PollPlanFailed);
            const cleanup_deadline = if (self.cleanup) |state|
                state.plan.detach_repaint_deadline_ns orelse
                    state.plan.global_deadline_ns
            else
                null;
            const timeout_ms = if (force_nonblocking_snapshot)
                @as(c_int, 0)
            else
                self.pollTimeoutMs(now_ns, cleanup_deadline) catch
                    return self.failRun(error.ClockFailed);
            _ = posix.poll(&self.pre_raw.poll_fds, timeout_ms) catch
                return self.failRun(error.PollFailed);
        }
    }

    const StartCleanupResult = union(enum) {
        started,
        projection_terminal: client_pump.TerminalReason,
        detach_terminal: client_pump.TerminalReason,
        invalid,
    };

    fn startCleanup(
        self: *IntegratedStackOwner,
        cause: external_loop_policy.CleanupCause,
        signal: ?posix.SIG,
        now_ns: i128,
    ) StartCleanupResult {
        return switch (self.beginCleanup(cause, signal, now_ns)) {
            .begun => .started,
            .busy => if (self.cleanup != null) .started else .invalid,
            .projection_terminal => |reason| .{ .projection_terminal = reason },
            .detach_terminal => |reason| .{ .detach_terminal = reason },
            .invalid => .invalid,
        };
    }

    fn detachTerminalError(reason: client_pump.TerminalReason) RunError {
        return switch (reason) {
            .protocol_error => error.CleanupDetachProtocolError,
            .invariant_failure => error.CleanupDetachInvariantFailure,
            else => error.CleanupDetachOtherTerminal,
        };
    }

    fn failRun(self: *IntegratedStackOwner, err: RunError) RunError {
        self.discardRepaints();
        _ = self.teardown();
        return err;
    }

    fn discardRepaints(self: *IntegratedStackOwner) void {
        if (self.pre_raw.repaint.current) |*frame| frame.deinit();
        self.pre_raw.repaint.current = null;
        if (self.pre_raw.repaint.latest) |*frame| frame.deinit();
        self.pre_raw.repaint.latest = null;
        self.stdout_progress = null;
    }

    pub fn teardown(self: *IntegratedStackOwner) external_pump_owner.PreRawTeardownResult {
        if (self.saved_self_addr == 0 and self.lifecycle == .empty) return .already_dead;
        if (self.saved_self_addr != @intFromPtr(self)) return .moved;
        if (self.lifecycle == .dead) return .already_dead;
        if (self.lifecycle == .preparing) return .busy;
        self.lifecycle = .tearing_down;
        const result = if (self.cleanup) |cleanup|
            if (cleanup.signal) |signal|
                self.pre_raw.teardownAndForwardSignal(signal)
            else
                self.pre_raw.teardown()
        else
            self.pre_raw.teardown();
        switch (result) {
            .cleaned, .cleaned_with_invariant, .already_dead, .pump_quarantined => {
                self.stdout_progress = null;
                self.lifecycle = .dead;
            },
            .moved, .busy, .restore_failed, .pump_busy => {},
        }
        return result;
    }

    fn requireLifecycle(
        self: *IntegratedStackOwner,
        expected: Lifecycle,
    ) external_pump_owner.PreRawCommitError!void {
        if (self.saved_self_addr != @intFromPtr(self)) return error.Moved;
        if (self.lifecycle != expected) return error.InvalidLifecycle;
    }

    fn settleFailedPreparation(self: *IntegratedStackOwner) void {
        switch (self.pre_raw.teardown()) {
            .cleaned, .cleaned_with_invariant, .already_dead, .pump_quarantined => self.lifecycle = .dead,
            .moved, .busy, .restore_failed, .pump_busy => {},
        }
    }
};

fn applyImmediatePollWake(
    validated_timeout_ms: c_int,
    host_immediate_interest: bool,
    pump_immediate: bool,
) c_int {
    return if (host_immediate_interest or pump_immediate) 0 else validated_timeout_ms;
}

fn pollInputOrTerminal(revents: i16) bool {
    return revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL) != 0;
}

fn terminalCleanupCause(
    reason: client_pump.TerminalReason,
) external_loop_policy.CleanupCause {
    return switch (reason) {
        .revoked => .revoked,
        .deadline_exceeded => .deadline,
        else => .host_error,
    };
}

fn monotonicNowNs() error{ClockFailed}!i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0)
        return error.ClockFailed;
    const seconds: i128 = @intCast(ts.sec);
    const nanos: i128 = @intCast(ts.nsec);
    return std.math.add(
        i128,
        std.math.mul(i128, seconds, std.time.ns_per_s) catch
            return error.ClockFailed,
        nanos,
    ) catch return error.ClockFailed;
}

test "p5c3d pump result preserves admitted TX interest until authority is clear" {
    var owner: IntegratedStackOwner = .{};
    owner.saved_self_addr = @intFromPtr(&owner);
    owner.lifecycle = .live;
    owner.socket_write_interest = true;

    // Inherited screen work does not inspect the TX queue. Its default false must not erase the
    // only POLLOUT wake for an already admitted key byte.
    owner.notePumpResult(.{ .authority_clear = false });
    try std.testing.expect(owner.socket_write_interest);
    try std.testing.expect(!owner.host_immediate_interest);

    // Kernel readiness may be fully consumed by the same turn that publishes a live screen owner.
    // The scheduler must retain that semantic wake until a later pump proves the owner clear.
    owner.notePumpResult(.{ .inherited_work_ready = true });
    try std.testing.expect(owner.host_immediate_interest);
    owner.notePumpResult(.{ .immediate_rx = true });
    try std.testing.expect(owner.host_immediate_interest);

    // A clear frontier makes the pump's queue projection authoritative.
    owner.notePumpResult(.{ .authority_clear = true, .write_interest = false });
    try std.testing.expect(!owner.socket_write_interest);
    try std.testing.expect(!owner.host_immediate_interest);

    owner.socket_write_interest = true;
    owner.notePumpResult(.{ .terminal = .{
        .reason = .socket_error,
        .fd_disposition = .owner_cleanup,
    } });
    try std.testing.expect(!owner.socket_write_interest);
    try std.testing.expect(!owner.host_immediate_interest);
    try std.testing.expect(!owner.stdin_interest);
}

test "p5c3d semantic self-wake converts an otherwise blocking poll to a kernel snapshot" {
    try std.testing.expectEqual(@as(c_int, 0), applyImmediatePollWake(-1, true, false));
    try std.testing.expectEqual(@as(c_int, 0), applyImmediatePollWake(50, false, true));
    try std.testing.expectEqual(@as(c_int, -1), applyImmediatePollWake(-1, false, false));
}

test "p5c3c-3b local stack binds chord and resize to one immutable initial role" {
    const size = external_tty.Size{ .cols = 123, .rows = 45 };
    var controller = try IntegratedLocalState.init(.controller, size);
    try std.testing.expectEqual(external_detach_chord.Role.controller, controller.chord.role);
    try std.testing.expectEqual(external_resize.Role.controller, controller.resize.role);
    try std.testing.expectEqual(size, controller.resize.initial_size);
    try std.testing.expect((try controller.resize.attached()) != null);

    var observer = try IntegratedLocalState.init(.observer, size);
    try std.testing.expectEqual(external_detach_chord.Role.observer, observer.chord.role);
    try std.testing.expectEqual(external_resize.Role.observer, observer.resize.role);
    try std.testing.expect((try observer.resize.attached()) == null);
    try std.testing.expect((try observer.feedInput('x', 1)).suppressed);
    _ = try observer.feedInput(external_detach_chord.prefix, 2);
    try std.testing.expect((try observer.feedInput(external_detach_chord.detach_byte, 3)).detached);

    try std.testing.expectEqualSlices(u8, "x", (try controller.feedInput('x', 1)).bytes());
}

test "p5c3c-3b local stack rejects an impossible initial terminal size" {
    try std.testing.expectError(
        error.InvalidSize,
        IntegratedLocalState.init(.controller, .{ .cols = 0, .rows = 24 }),
    );
    try std.testing.expectError(
        error.InvalidSize,
        IntegratedLocalState.init(.observer, .{ .cols = 80, .rows = 0 }),
    );
}

test "p5c3c-3b uncommitted integrated owner rejects pump and input without mutation" {
    var owner: IntegratedStackOwner = .{};
    const turn = owner.pumpHost(.{
        .readable = true,
        .writable = true,
        .now_ns = 1,
    }, std.testing.io);
    try std.testing.expectEqual(client_pump.TerminalReason.invariant_failure, turn.terminal.?.reason);
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        owner.admitInputByte('x', 1).terminal,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        owner.flushStdout(1).terminal,
    );
    try std.testing.expectError(error.Moved, owner.refreshPollInterests());
    try std.testing.expectError(error.Moved, owner.pollTimeoutMs(1, null));
    try std.testing.expectError(error.Moved, owner.nextAction(1));
    try std.testing.expectError(error.Moved, owner.executeReadyAction(1, std.testing.io));
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        owner.drainSignalWake().terminal,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        owner.applyPendingResize(1).terminal,
    );
    try std.testing.expectEqual(
        client_pump.TerminalReason.invariant_failure,
        owner.drainStdin(1).terminal,
    );
    try std.testing.expectEqual(
        external_pump_owner.PreRawTeardownResult.already_dead,
        owner.teardown(),
    );
}

test "p5c3c-3b actual openpty integrated owner commits raw and restores exact ANSI and termios" {
    const external_ansi = @import("external_ansi.zig");
    const Report = extern struct {
        repaint_len: u64,
        repaint_digest: [32]u8,
    };
    const window: posix.winsize = .{ .row = 3, .col = 5, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var report_pipe: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&report_pipe));
    defer _ = c.close(report_pipe[0]);

    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = c.close(master);
        _ = c.close(report_pipe[0]);
        var fixture = external_pump_owner.testing.preparedFixture(0x3b01) catch c._exit(120);
        var owner: IntegratedStackOwner = .{};
        owner.prepareInPlace(
            &fixture.prepared,
            std.heap.page_allocator,
            std.testing.io,
            slave,
            slave,
        ) catch c._exit(121);
        owner.commit() catch c._exit(122);
        switch (owner.projectCleanupWireAuthority()) {
            .authority => |authority| if (authority != .none) c._exit(167),
            else => c._exit(168),
        }
        switch (owner.applyPendingResize(1)) {
            .admitted => {},
            .idle => c._exit(160),
            .suppressed => c._exit(162),
            .backpressure => c._exit(163),
            .busy => c._exit(164),
            .terminal => |reason| c._exit(180 + @as(c_int, @intFromEnum(reason))),
        }
        if (owner.pending_resize or owner.pending_resize_request != null) c._exit(161);
        if (!owner.socket_write_interest) c._exit(166);
        switch (owner.projectCleanupWireAuthority()) {
            .authority => |authority| if (authority != .control_in_flight) c._exit(169),
            else => c._exit(170),
        }
        owner.pending_resize = true;
        owner.refreshPollInterests() catch c._exit(139);
        owner.pre_raw.poll_fds[0].revents = posix.POLL.IN;
        owner.pre_raw.poll_fds[1].revents = posix.POLL.IN | posix.POLL.OUT;
        owner.pre_raw.poll_fds[2].revents = posix.POLL.OUT;
        owner.pre_raw.poll_fds[3].revents = posix.POLL.IN;
        if ((owner.nextAction(0) catch c._exit(140)) != .termination_signal) c._exit(141);
        owner.pre_raw.poll_fds[3].revents = 0;
        if ((owner.nextAction(0) catch c._exit(142)) != .host_rx) c._exit(143);
        owner.pre_raw.poll_fds[1].revents = posix.POLL.OUT;
        _ = owner.local.feedInput(external_detach_chord.prefix, 0) catch c._exit(144);
        if ((owner.pollTimeoutMs(0, null) catch c._exit(145)) != 1000) c._exit(146);
        if ((owner.nextAction(external_detach_chord.timeout_ns) catch c._exit(147)) !=
            .chord_deadline) c._exit(148);
        _ = owner.local.chord.expire(external_detach_chord.timeout_ns) catch c._exit(149);
        if ((owner.nextAction(external_detach_chord.timeout_ns) catch c._exit(150)) !=
            .socket_tx) c._exit(151);
        owner.socket_write_interest = false;
        if ((owner.nextAction(external_detach_chord.timeout_ns) catch c._exit(152)) !=
            .stdout_tx) c._exit(153);
        owner.pre_raw.poll_fds[2].revents = 0;
        if ((owner.nextAction(external_detach_chord.timeout_ns) catch c._exit(154)) !=
            .resize) c._exit(155);
        owner.pending_resize = false;
        if ((owner.nextAction(external_detach_chord.timeout_ns) catch c._exit(156)) !=
            .stdin_rx) c._exit(157);
        owner.pre_raw.poll_fds[0].revents = 0;
        if ((owner.nextAction(external_detach_chord.timeout_ns) catch c._exit(158)) !=
            .poll_wait) c._exit(159);
        const repaint = owner.pre_raw.repaint.current orelse c._exit(123);
        var report = Report{
            .repaint_len = repaint.bytes.len,
            .repaint_digest = undefined,
        };
        std.crypto.hash.sha2.Sha256.hash(repaint.bytes, &report.repaint_digest, .{});
        switch (owner.flushStdout(1)) {
            .progressed => |progress| if (!progress.frame_complete or
                progress.bytes != repaint.bytes.len) c._exit(124),
            else => c._exit(125),
        }
        if (c.write(
            report_pipe[1],
            std.mem.asBytes(&report).ptr,
            @sizeOf(Report),
        ) != @sizeOf(Report)) c._exit(126);
        _ = c.close(report_pipe[1]);
        if (owner.teardown() != .cleaned) c._exit(127);
        external_pump_owner.testing.deinitPreparedFixture(&fixture);
        c._exit(0);
    }
    _ = c.close(report_pipe[1]);

    var report: Report = undefined;
    try readExactTestFd(report_pipe[0], std.mem.asBytes(&report));
    try std.testing.expect(report.repaint_len > 0);
    const output_len = std.math.add(
        usize,
        external_ansi.enter_bytes.len + external_ansi.leave_bytes.len,
        std.math.cast(usize, report.repaint_len) orelse return error.TestUnexpectedResult,
    ) catch return error.TestUnexpectedResult;
    const output = try std.testing.allocator.alloc(u8, output_len);
    defer std.testing.allocator.free(output);
    try readExactTestFd(master, output);

    const wait_status = try waitChildTestDeadline(child, child_wait_timeout_ms);
    try std.testing.expect(c.W.IFEXITED(wait_status));
    try std.testing.expectEqual(@as(c_int, 0), c.W.EXITSTATUS(wait_status));
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.enter_bytes,
        output[0..external_ansi.enter_bytes.len],
    );
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.leave_bytes,
        output[output.len - external_ansi.leave_bytes.len ..],
    );
    var repaint_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        output[external_ansi.enter_bytes.len .. output.len - external_ansi.leave_bytes.len],
        &repaint_digest,
        .{},
    );
    try std.testing.expectEqualSlices(u8, &report.repaint_digest, &repaint_digest);
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "p5c3c-3b actual openpty stdout backpressure preserves one immutable partial frame" {
    const external_ansi = @import("external_ansi.zig");
    const Report = extern struct {
        written: u64,
        prefix_digest: [32]u8,
    };
    const window: posix.winsize = .{ .row = 100, .col = 1000, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var report_pipe: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&report_pipe));
    defer _ = c.close(report_pipe[0]);

    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = c.close(master);
        _ = c.close(report_pipe[0]);
        var fixture = external_pump_owner.testing.preparedFixture(0x3b02) catch c._exit(130);
        var owner: IntegratedStackOwner = .{};
        owner.prepareInPlace(
            &fixture.prepared,
            std.heap.page_allocator,
            std.testing.io,
            slave,
            slave,
        ) catch c._exit(131);
        owner.commit() catch c._exit(132);
        if (owner.pre_raw.repaint.current) |*initial| initial.deinit();
        const pressure = std.heap.page_allocator.alloc(
            u8,
            2 * external_loop_policy.stdout_budget_bytes,
        ) catch c._exit(133);
        for (pressure, 0..) |*byte, index| byte.* = @intCast(index % 251);
        owner.pre_raw.repaint.current = .{
            .projection_sequence = owner.pre_raw.next_projection_sequence,
            .bytes = pressure,
            .storage = pressure,
            .allocator = std.heap.page_allocator,
        };
        const frame = owner.pre_raw.repaint.current orelse c._exit(133);
        const progress = switch (owner.flushStdout(1)) {
            .progressed => |value| value,
            else => c._exit(134),
        };
        if (progress.frame_complete or progress.bytes == 0 or
            progress.bytes >= external_loop_policy.stdout_budget_bytes) c._exit(135);
        if (owner.stdout_progress == null or
            owner.stdout_progress.?.offset != progress.bytes) c._exit(136);
        var report = Report{ .written = progress.bytes, .prefix_digest = undefined };
        std.crypto.hash.sha2.Sha256.hash(
            frame.bytes[0..progress.bytes],
            &report.prefix_digest,
            .{},
        );
        if (c.write(
            report_pipe[1],
            std.mem.asBytes(&report).ptr,
            @sizeOf(Report),
        ) != @sizeOf(Report)) c._exit(137);
        _ = c.close(report_pipe[1]);
        if (owner.teardown() != .cleaned) c._exit(138);
        external_pump_owner.testing.deinitPreparedFixture(&fixture);
        c._exit(0);
    }
    _ = c.close(report_pipe[1]);

    var report: Report = undefined;
    try readExactTestFd(report_pipe[0], std.mem.asBytes(&report));
    const written = std.math.cast(usize, report.written) orelse return error.TestUnexpectedResult;
    try std.testing.expect(written > 0);
    try std.testing.expect(written < external_loop_policy.stdout_budget_bytes);
    const output = try std.testing.allocator.alloc(u8, external_ansi.enter_bytes.len + written);
    defer std.testing.allocator.free(output);
    try readExactTestFd(master, output);
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.enter_bytes,
        output[0..external_ansi.enter_bytes.len],
    );
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        output[external_ansi.enter_bytes.len..],
        &digest,
        .{},
    );
    try std.testing.expectEqualSlices(u8, &report.prefix_digest, &digest);
    try expectChildExitZero(child);
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "p5c3c-3b actual openpty stdin reaches one MRSH input frame without byte loss" {
    const external_ansi = @import("external_ansi.zig");
    const window: posix.winsize = .{ .row = 3, .col = 5, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var ready_pipe: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready_pipe));
    defer _ = c.close(ready_pipe[0]);

    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = c.close(master);
        _ = c.close(ready_pipe[0]);
        var fixture = external_pump_owner.testing.preparedFixture(0x3b03) catch c._exit(170);
        var owner: IntegratedStackOwner = .{};
        owner.prepareInPlace(
            &fixture.prepared,
            std.heap.page_allocator,
            std.testing.io,
            slave,
            slave,
        ) catch c._exit(171);
        owner.commit() catch c._exit(172);
        const ready = [1]u8{1};
        if (c.write(ready_pipe[1], &ready, ready.len) != ready.len) c._exit(174);
        _ = c.close(ready_pipe[1]);
        var stdin_poll = [_]posix.pollfd{.{ .fd = slave, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&stdin_poll, 5_000) catch c._exit(175)) != 1) c._exit(176);
        switch (owner.drainStdin(1)) {
            .progressed => |progress| if (progress.bytes_read != 1 or
                progress.bytes_admitted != 1 or progress.bytes_suppressed != 0) c._exit(177),
            else => c._exit(178),
        }
        if (!owner.socket_write_interest) c._exit(184);
        switch (owner.projectCleanupWireAuthority()) {
            .authority => |authority| if (authority != .offset_zero) c._exit(185),
            else => c._exit(186),
        }
        owner.refreshPollInterests() catch c._exit(185);
        if (owner.pre_raw.poll_fds[1].events & posix.POLL.OUT == 0) c._exit(186);
        var sent = false;
        for (0..4) |index| {
            owner.pre_raw.poll_fds[1].revents = posix.POLL.OUT;
            const execution = owner.executeReadyAction(
                2 + @as(i128, @intCast(index)),
                std.testing.io,
            ) catch c._exit(187);
            const turn = switch (execution) {
                .pump => |value| value,
                else => c._exit(188),
            };
            if (turn.terminal) |terminal|
                c._exit(190 + @as(c_int, @intFromEnum(terminal.reason)));
            if (turn.tx_bytes != 0) {
                sent = true;
                break;
            }
        }
        if (!sent) c._exit(179);
        if (owner.socket_write_interest) c._exit(189);
        switch (owner.projectCleanupWireAuthority()) {
            .authority => |authority| if (authority != .none) c._exit(190),
            else => c._exit(191),
        }
        var wire: [protocol.header_size + 1]u8 = undefined;
        readExactTestFd(fixture.peer_fd, &wire) catch c._exit(180);
        const header: *const [protocol.header_size]u8 = @ptrCast(&wire);
        const decoded = protocol.Header.decode(header) catch c._exit(181);
        if (decoded.kind != .input_bytes or decoded.stream_id != 7 or
            decoded.request_id != 0 or decoded.payload_len != 1 or
            wire[protocol.header_size] != 'x') c._exit(182);
        if (owner.pre_raw.repaint.current) |*frame| frame.deinit();
        owner.pre_raw.repaint.current = null;
        switch (owner.beginCleanup(.local_detach, null, 10)) {
            .begun => |plan| if (!plan.detach_allowed or plan.fail_close_socket) c._exit(197),
            else => c._exit(198),
        }
        const detach_turn = owner.pumpHost(.{
            .readable = true,
            .writable = true,
            .now_ns = 11,
        }, std.testing.io);
        if (detach_turn.terminal != null) c._exit(208);
        if (detach_turn.tx_frames != 1 or detach_turn.tx_bytes == 0) c._exit(209);
        switch (owner.driveCleanup(11, std.testing.io)) {
            .cleaned => |result| if (result != .cleaned) c._exit(199),
            else => c._exit(200),
        }
        var detach_header_bytes: [protocol.header_size]u8 = undefined;
        readExactTestFd(fixture.peer_fd, &detach_header_bytes) catch c._exit(201);
        const detach_header = protocol.Header.decode(&detach_header_bytes) catch c._exit(202);
        if (detach_header.kind != .request or detach_header.stream_id != 0 or
            detach_header.request_id == 0 or detach_header.payload_len == 0 or
            detach_header.payload_len > 128) c._exit(203);
        var detach_payload: [128]u8 = undefined;
        readExactTestFd(
            fixture.peer_fd,
            detach_payload[0..detach_header.payload_len],
        ) catch c._exit(204);
        if (std.mem.indexOf(
            u8,
            detach_payload[0..detach_header.payload_len],
            "\"method\":\"runtime.detach\"",
        ) == null or std.mem.indexOf(
            u8,
            detach_payload[0..detach_header.payload_len],
            "\"stream_id\":7",
        ) == null) c._exit(205);
        external_pump_owner.testing.deinitPreparedFixture(&fixture);
        c._exit(0);
    }
    _ = c.close(ready_pipe[1]);
    var ready: [1]u8 = undefined;
    try readExactTestFd(ready_pipe[0], &ready);
    try std.testing.expectEqual(@as(u8, 1), ready[0]);
    try std.testing.expectEqual(@as(isize, 1), c.write(master, "x", 1));
    var output: [external_ansi.enter_bytes.len + external_ansi.leave_bytes.len]u8 = undefined;
    try readExactTestFd(master, &output);
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.enter_bytes,
        output[0..external_ansi.enter_bytes.len],
    );
    try std.testing.expectEqualSlices(
        u8,
        external_ansi.leave_bytes,
        output[external_ansi.enter_bytes.len..],
    );
    try expectChildExitZero(child);
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "p5c3c-3b actual poll loop suppresses observer input and detaches with restored tty" {
    const external_ansi = @import("external_ansi.zig");
    const window: posix.winsize = .{ .row = 6, .col = 12, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try external_pump_owner.testing.preparedFixture(0x3b05);
    defer external_pump_owner.testing.deinitPreparedFixture(&fixture);
    fixture.prepared.attachment.state.role = .observer;

    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = c.close(master);
        _ = c.close(fixture.peer_fd);
        var owner: IntegratedStackOwner = .{};
        owner.prepareInPlace(
            &fixture.prepared,
            std.heap.page_allocator,
            std.testing.io,
            slave,
            slave,
        ) catch c._exit(230);
        owner.commit() catch c._exit(231);
        const result = owner.run(std.testing.io) catch c._exit(233);
        if (result.cause != .local_detach or result.terminal_reason != null or
            result.teardown != .cleaned) c._exit(234);
        c._exit(0);
    }

    var enter: [external_ansi.enter_bytes.len]u8 = undefined;
    try readExactTestFd(master, &enter);
    try std.testing.expectEqualSlices(u8, external_ansi.enter_bytes, &enter);
    const input = [_]u8{ 'x', external_detach_chord.prefix, external_detach_chord.detach_byte };
    try std.testing.expectEqual(
        @as(isize, input.len),
        c.write(master, &input, input.len),
    );

    var detach_header_bytes: [protocol.header_size]u8 = undefined;
    try readExactTestFd(fixture.peer_fd, &detach_header_bytes);
    const detach_header = try protocol.Header.decode(&detach_header_bytes);
    try std.testing.expectEqual(protocol.Kind.request, detach_header.kind);
    try std.testing.expectEqual(@as(u64, 0), detach_header.stream_id);
    try std.testing.expect(detach_header.request_id != 0);
    try std.testing.expect(detach_header.payload_len > 0 and detach_header.payload_len <= 128);
    var payload: [128]u8 = undefined;
    try readExactTestFd(fixture.peer_fd, payload[0..detach_header.payload_len]);
    try std.testing.expect(std.mem.indexOf(
        u8,
        payload[0..detach_header.payload_len],
        "\"method\":\"runtime.detach\"",
    ) != null);

    var output: [64 * 1024]u8 = undefined;
    var output_len: usize = 0;
    while (std.mem.indexOf(u8, output[0..output_len], external_ansi.leave_bytes) == null) {
        if (output_len == output.len) return error.TestUnexpectedResult;
        var ready = [_]posix.pollfd{.{
            .fd = master,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if (try posix.poll(&ready, 5_000) != 1) return error.TestTimedOut;
        const count = c.read(master, output[output_len..].ptr, output.len - output_len);
        if (count > 0) {
            output_len += @intCast(count);
            continue;
        }
        if (count < 0 and posix.errno(count) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
    try expectChildExitZero(child);
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "p5c3c-3b actual poll loop restores tty before forwarding termination signal" {
    const external_ansi = @import("external_ansi.zig");
    const window: posix.winsize = .{ .row = 5, .col = 10, .xpixel = 0, .ypixel = 0 };
    var master: c.fd_t = -1;
    var slave: c.fd_t = -1;
    try std.testing.expectEqual(@as(c_int, 0), openpty(
        &master,
        &slave,
        null,
        null,
        &window,
    ));
    defer _ = c.close(master);
    defer _ = c.close(slave);
    const before = try posix.tcgetattr(slave);
    var fixture = try external_pump_owner.testing.preparedFixture(0x3b06);
    defer external_pump_owner.testing.deinitPreparedFixture(&fixture);
    fixture.prepared.attachment.state.role = .observer;

    const child = c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    var child_reaped = false;
    errdefer if (!child_reaped) {
        _ = c.kill(child, posix.SIG.KILL);
        var ignored: c_int = 0;
        _ = c.waitpid(child, &ignored, 0);
    };
    if (child == 0) {
        _ = c.close(master);
        _ = c.close(fixture.peer_fd);
        var owner: IntegratedStackOwner = .{};
        owner.prepareInPlace(
            &fixture.prepared,
            std.heap.page_allocator,
            std.testing.io,
            slave,
            slave,
        ) catch c._exit(240);
        owner.commit() catch c._exit(241);
        _ = owner.run(std.testing.io) catch c._exit(243);
        c._exit(244);
    }

    var enter: [external_ansi.enter_bytes.len]u8 = undefined;
    try readExactTestFd(master, &enter);
    try std.testing.expectEqualSlices(u8, external_ansi.enter_bytes, &enter);
    try std.testing.expectEqual(@as(c_int, 0), c.kill(child, posix.SIG.TERM));

    var output: [64 * 1024]u8 = undefined;
    var output_len: usize = 0;
    while (std.mem.indexOf(u8, output[0..output_len], external_ansi.leave_bytes) == null) {
        if (output_len == output.len) return error.TestUnexpectedResult;
        var ready = [_]posix.pollfd{.{
            .fd = master,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        if (try posix.poll(&ready, 5_000) != 1) return error.TestTimedOut;
        const count = c.read(master, output[output_len..].ptr, output.len - output_len);
        if (count > 0) {
            output_len += @intCast(count);
            continue;
        }
        if (count < 0 and posix.errno(count) == .INTR) continue;
        return error.TestUnexpectedResult;
    }

    // **여기도 마감을 건다**(위 `expectChildExitZero` 와 같은 이유). 이 판정자는 자식이 신호로
    // 죽기를 기다리는데, 그 신호가 안 닿거나 자식이 pty 에서 막히면 무한히 앉아 있게 된다.
    const wait_status = try waitChildTestDeadline(child, child_wait_timeout_ms);
    child_reaped = true;
    try std.testing.expect(c.W.IFSIGNALED(wait_status));
    try std.testing.expectEqual(posix.SIG.TERM, c.W.TERMSIG(wait_status));
    const after = try posix.tcgetattr(slave);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&before), std.mem.asBytes(&after));
}

test "p5c3c-3b offset-zero cleanup cancellation retires queued input before detach" {
    var fixture = try external_pump_owner.testing.preparedFixture(0x3b04);
    defer external_pump_owner.testing.deinitPreparedFixture(&fixture);
    var owner: external_pump_owner.ExternalPumpOwner = .{};
    try owner.initInPlace(&fixture.prepared);
    defer _ = owner.teardown();
    try std.testing.expect(owner.admitTx(.{
        .kind = .input_bytes,
        .stream_id = owner.attachment.state.stream_id,
        .payload = "cancel-before-wire",
        .request_policy = .zero,
    }, 1) == .admitted);
    switch (owner.projectCleanupWireAuthority()) {
        .authority => |authority| try std.testing.expectEqual(
            external_pump_owner.CleanupWireAuthority.offset_zero,
            authority,
        ),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(
        external_pump_owner.CleanupCancelResult.cancelled,
        owner.cancelOffsetZeroInputForCleanup(2),
    );
    switch (owner.projectCleanupWireAuthority()) {
        .authority => |authority| try std.testing.expectEqual(
            external_pump_owner.CleanupWireAuthority.none,
            authority,
        ),
        else => return error.TestUnexpectedResult,
    }
}

fn readExactTestFd(fd: c.fd_t, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 5_000) != 1) return error.TestTimedOut;
        const count = c.read(fd, destination[offset..].ptr, destination.len - offset);
        if (count > 0) {
            offset += @intCast(count);
        } else if (count < 0 and posix.errno(count) == .INTR) {
            continue;
        } else return error.TestUnexpectedResult;
    }
}

/// 자식을 기다리는 **모든** 자리가 쓰는 마감(ms). 한 곳에 둔다 — 값이 갈리면 "여기는 왜 다른가" 가
/// 판정마다 생기고, 그 답을 아무도 안 적는다.
const child_wait_timeout_ms: i64 = 5_000;

/// 자식이 0으로 끝났는지 본다. **반드시 마감을 건다.**
///
/// 예전에는 블로킹 `waitpid`(`WNOHANG` 없이)로 **무한히** 기다렸다. 이 파일의 판정자들은 실제
/// `openpty` 위에서 역압·부분 프레임 같은 **막히는 상태를 일부러 만들기** 때문에, 자식이 pty 쓰기에서
/// 멈추면 부모가 영원히 앉아 있는다 — CI 에서 `actual openpty stdout backpressure preserves one
/// immutable partial frame` 이 **32분** 매달려 잡이 통째로 취소됐고(2026-08-31), 정리 로그에 자식
/// 프로세스 둘이 고아로 남았다. 그 잡이 무관한 PR 다섯을 연달아 막았다.
///
/// 마감이 있으면 같은 상황이 **몇 초짜리 읽을 수 있는 실패**가 된다 — `waitChildTestDeadline` 이
/// 자식을 죽이고 `TestTimedOut` 을 낸다. 이 파일의 다른 판정자는 이미 그쪽을 쓰고 있었다.
fn expectChildExitZero(child: c.pid_t) !void {
    const wait_status = try waitChildTestDeadline(child, child_wait_timeout_ms);
    try std.testing.expect(c.W.IFEXITED(wait_status));
    try std.testing.expectEqual(@as(c_int, 0), c.W.EXITSTATUS(wait_status));
}

fn waitChildTestDeadline(child: c.pid_t, timeout_ms: i64) !u32 {
    var status: c_int = 0;
    const started = std.Io.Timestamp.now(std.testing.io, .awake);
    while (started.untilNow(std.testing.io, .awake).toMilliseconds() < timeout_ms) {
        const waited = c.waitpid(child, &status, c.W.NOHANG);
        if (waited == child) return @bitCast(status);
        if (waited < 0 and posix.errno(waited) == .INTR) continue;
        if (waited < 0) return error.TestUnexpectedResult;
        _ = usleep(10_000);
    }
    _ = c.kill(child, posix.SIG.KILL);
    _ = c.waitpid(child, &status, 0);
    return error.TestTimedOut;
}
