//! P5c3c-3b external raw-loop orchestration policy.
//!
//! The Client pump remains the sole owner of MRSH RX/TX semantics. This leaf chooses only the
//! cross-domain order around it and the cleanup budget; keeping those decisions pure prevents the
//! eventual POSIX loop from growing a second, subtly different priority table.

const std = @import("std");

pub const normal_cleanup_ns: i128 = 200 * std.time.ns_per_ms;
pub const normal_prefix_ns: i128 = 100 * std.time.ns_per_ms;
pub const failure_cleanup_ns: i128 = 100 * std.time.ns_per_ms;
pub const socket_rx_budget_bytes: usize = 1024 * 1024;
pub const socket_tx_budget_bytes: usize = 1024 * 1024;
pub const socket_rx_budget_frames: usize = 64;
pub const socket_tx_budget_frames: usize = 64;
pub const stdin_budget_bytes: usize = 64 * 1024;
pub const stdout_budget_bytes: usize = 64 * 1024;

/// Absolute wake sources owned by the integrated loop. Keeping this closed list makes a newly
/// introduced deadline fail review visibly instead of being silently omitted from `poll(2)`.
pub const DeadlineSet = struct {
    signal_ns: ?i128 = null,
    chord_ns: ?i128 = null,
    resize_ns: ?i128 = null,
    control_ns: ?i128 = null,
    io_ns: ?i128 = null,
    cleanup_ns: ?i128 = null,
};

pub const PollTimeoutError = error{ InvalidClock, InvalidDeadline };

/// Converts the earliest absolute deadline to a Darwin `poll(2)` timeout.
///
/// Sub-millisecond remainders intentionally become zero: rounding up could sleep beyond an
/// absolute protocol or cleanup deadline. `-1` is returned only when no deadline exists.
pub fn pollTimeoutMs(now_ns: i128, deadlines: DeadlineSet) PollTimeoutError!c_int {
    if (now_ns < 0) return error.InvalidClock;
    var earliest: ?i128 = null;
    inline for (.{
        deadlines.signal_ns,
        deadlines.chord_ns,
        deadlines.resize_ns,
        deadlines.control_ns,
        deadlines.io_ns,
        deadlines.cleanup_ns,
    }) |candidate| {
        if (candidate) |deadline| {
            if (deadline < 0) return error.InvalidDeadline;
            earliest = if (earliest) |current| @min(current, deadline) else deadline;
        }
    }
    const deadline = earliest orelse return -1;
    if (deadline <= now_ns) return 0;
    const milliseconds = @divFloor(deadline - now_ns, std.time.ns_per_ms);
    return @intCast(@min(milliseconds, std.math.maxInt(c_int)));
}

pub const Action = enum {
    termination_signal,
    host_rx,
    chord_deadline,
    socket_tx,
    host_immediate,
    stdout_tx,
    resize,
    stdin_rx,
    poll_wait,
};

pub const TurnReadiness = struct {
    termination_signal: bool = false,
    /// Readiness for the RX-first Client pump. The action may subsequently yield a revoke, EOF,
    /// protocol terminal, or ordinary screen/event progress.
    host_rx: bool = false,
    chord_deadline: bool = false,
    socket_tx: bool = false,
    /// Owner-internal work (for example a completed control response) that no longer has a
    /// corresponding socket readiness edge but must run before lower-priority local work.
    host_immediate: bool = false,
    stdout_tx: bool = false,
    resize: bool = false,
    retained_stdin: bool = false,
    stdin_rx: bool = false,
};

pub fn selectAction(ready: TurnReadiness) Action {
    if (ready.termination_signal) return .termination_signal;
    if (ready.host_rx) return .host_rx;
    if (ready.chord_deadline) return .chord_deadline;
    if (ready.socket_tx) return .socket_tx;
    if (ready.stdout_tx) return .stdout_tx;
    // An immediate semantic suffix can remain armed while a just-completed resize response is
    // paired with its owner event. Consume one already-polled stdin turn first so the local
    // detach chord cannot be starved. The loop clears that readiness snapshot before re-entry,
    // therefore ordinary input cannot continuously outrun the host suffix.
    if (ready.host_immediate and ready.stdin_rx) return .stdin_rx;
    if (ready.host_immediate) return .host_immediate;
    if (ready.resize) return .resize;
    if (ready.retained_stdin) return .stdin_rx;
    if (ready.stdin_rx) return .stdin_rx;
    return .poll_wait;
}

/// A completed semantic suffix has already consumed its self-wake. If lower-priority owner-local
/// work remains, take exactly one nonblocking kernel snapshot before selecting it so a concurrent
/// signal/revoke/readiness edge keeps priority without stranding the local work in an unbounded
/// poll.
pub fn postImmediatePollMustBeNonblocking(action: Action, ready: TurnReadiness) bool {
    return action == .host_immediate and (ready.resize or ready.retained_stdin);
}

pub const CleanupCause = enum {
    local_detach,
    signal,
    revoked,
    host_error,
    deadline,
};

/// The only wire facts the outer loop may use. It must not inspect Client queue internals.
pub const WireAuthority = enum {
    none,
    offset_zero,
    control_in_flight,
    partial_frame,
    response_wait,
};

pub const CleanupPlan = struct {
    detach_allowed: bool,
    cancel_zero_offset_tx: bool,
    fail_close_socket: bool,
    discard_active_repaint: bool,
    discard_latest_repaint: bool,
    global_deadline_ns: i128,
    detach_repaint_deadline_ns: ?i128,
    leave_deadline_ns: i128,
};

pub const PlanError = error{ InvalidClock, DeadlineOverflow };

pub fn planCleanup(
    cause: CleanupCause,
    wire: WireAuthority,
    start_ns: i128,
) PlanError!CleanupPlan {
    if (start_ns < 0) return error.InvalidClock;
    return switch (cause) {
        .local_detach => blk: {
            const global = std.math.add(i128, start_ns, normal_cleanup_ns) catch
                return error.DeadlineOverflow;
            const prefix = std.math.add(i128, start_ns, normal_prefix_ns) catch
                return error.DeadlineOverflow;
            const wire_blocks_detach = switch (wire) {
                .control_in_flight, .partial_frame, .response_wait => true,
                .none, .offset_zero => false,
            };
            break :blk .{
                .detach_allowed = !wire_blocks_detach,
                .cancel_zero_offset_tx = wire == .offset_zero,
                .fail_close_socket = wire_blocks_detach,
                .discard_active_repaint = false,
                .discard_latest_repaint = false,
                .global_deadline_ns = global,
                .detach_repaint_deadline_ns = if (wire_blocks_detach) null else prefix,
                .leave_deadline_ns = global,
            };
        },
        .signal, .revoked, .host_error, .deadline => blk: {
            const global = std.math.add(i128, start_ns, failure_cleanup_ns) catch
                return error.DeadlineOverflow;
            break :blk .{
                .detach_allowed = false,
                .cancel_zero_offset_tx = false,
                .fail_close_socket = true,
                .discard_active_repaint = true,
                .discard_latest_repaint = true,
                .global_deadline_ns = global,
                .detach_repaint_deadline_ns = null,
                .leave_deadline_ns = global,
            };
        },
    };
}

test "p5c3c-3b turn priority gives one ready stdin turn before immediate host work" {
    const all = TurnReadiness{
        .termination_signal = true,
        .host_rx = true,
        .chord_deadline = true,
        .socket_tx = true,
        .host_immediate = true,
        .stdout_tx = true,
        .resize = true,
        .stdin_rx = true,
    };
    try std.testing.expectEqual(Action.termination_signal, selectAction(all));

    var remaining = all;
    remaining.termination_signal = false;
    try std.testing.expectEqual(Action.host_rx, selectAction(remaining));
    remaining.host_rx = false;
    try std.testing.expectEqual(Action.chord_deadline, selectAction(remaining));
    remaining.chord_deadline = false;
    try std.testing.expectEqual(Action.socket_tx, selectAction(remaining));
    remaining.socket_tx = false;
    try std.testing.expectEqual(Action.stdout_tx, selectAction(remaining));
    remaining.stdout_tx = false;
    try std.testing.expectEqual(Action.stdin_rx, selectAction(remaining));
    remaining.stdin_rx = false;
    try std.testing.expectEqual(Action.host_immediate, selectAction(remaining));
    remaining.host_immediate = false;
    try std.testing.expectEqual(Action.resize, selectAction(remaining));
    remaining.resize = false;
    try std.testing.expectEqual(Action.poll_wait, selectAction(remaining));

    // Without an immediate host suffix, the established resize-before-stdin ordering remains.
    var ordinary = TurnReadiness{ .resize = true, .stdin_rx = true };
    try std.testing.expectEqual(Action.resize, selectAction(ordinary));
    ordinary.resize = false;
    try std.testing.expectEqual(Action.stdin_rx, selectAction(ordinary));

    // Retained bytes are a scheduler-owned wake after control backpressure clears; they do not
    // masquerade as a fresh kernel-readiness bit while immediate host work is still armed.
    var retained = TurnReadiness{ .host_immediate = true, .retained_stdin = true };
    try std.testing.expectEqual(Action.host_immediate, selectAction(retained));
    retained.host_immediate = false;
    try std.testing.expectEqual(Action.stdin_rx, selectAction(retained));

    try std.testing.expect(postImmediatePollMustBeNonblocking(.host_immediate, .{
        .resize = true,
    }));
    try std.testing.expect(postImmediatePollMustBeNonblocking(.host_immediate, .{
        .retained_stdin = true,
    }));
    try std.testing.expect(!postImmediatePollMustBeNonblocking(.host_rx, .{
        .resize = true,
    }));
    try std.testing.expect(!postImmediatePollMustBeNonblocking(.host_immediate, .{}));
}

test "p5c3c-3b normal cleanup appends detach only without in-flight wire authority" {
    const start: i128 = 1_000;
    const no_wire = try planCleanup(.local_detach, .none, start);
    try std.testing.expect(no_wire.detach_allowed);
    try std.testing.expect(!no_wire.cancel_zero_offset_tx);
    const clean = try planCleanup(.local_detach, .offset_zero, start);
    try std.testing.expect(clean.detach_allowed);
    try std.testing.expect(clean.cancel_zero_offset_tx);
    try std.testing.expectEqual(start + normal_cleanup_ns, clean.global_deadline_ns);
    try std.testing.expectEqual(start + normal_prefix_ns, clean.detach_repaint_deadline_ns.?);
    try std.testing.expectEqual(start + normal_cleanup_ns, clean.leave_deadline_ns);

    inline for (.{ WireAuthority.control_in_flight, .partial_frame, .response_wait }) |wire| {
        const plan = try planCleanup(.local_detach, wire, start);
        try std.testing.expect(!plan.detach_allowed);
        try std.testing.expect(plan.fail_close_socket);
        try std.testing.expect(!plan.cancel_zero_offset_tx);
    }
}

test "p5c3c-3b signal revoke and error discard work and bound leave to one hundred milliseconds" {
    const start: i128 = 42;
    inline for (.{ CleanupCause.signal, .revoked, .host_error, .deadline }) |cause| {
        const plan = try planCleanup(cause, .offset_zero, start);
        try std.testing.expect(!plan.detach_allowed);
        try std.testing.expect(plan.discard_active_repaint);
        try std.testing.expect(plan.discard_latest_repaint);
        try std.testing.expect(plan.fail_close_socket);
        try std.testing.expectEqual(start + failure_cleanup_ns, plan.global_deadline_ns);
        try std.testing.expectEqual(plan.global_deadline_ns, plan.leave_deadline_ns);
        try std.testing.expect(plan.detach_repaint_deadline_ns == null);
    }
}

test "p5c3c-3b cleanup deadline overflow is rejected before a plan is minted" {
    try std.testing.expectError(
        error.DeadlineOverflow,
        planCleanup(.local_detach, .none, std.math.maxInt(i128)),
    );
    try std.testing.expectError(
        error.InvalidClock,
        planCleanup(.signal, .none, -1),
    );
}

test "p5c3c-3b poll timeout is the minimum absolute deadline and never rounds past it" {
    const now: i128 = 5 * std.time.ns_per_s;
    const deadlines = DeadlineSet{
        .signal_ns = now + 30 * std.time.ns_per_ms,
        .chord_ns = now + 8 * std.time.ns_per_ms + 900_000,
        .resize_ns = now + 20 * std.time.ns_per_ms,
        .control_ns = now + 12 * std.time.ns_per_ms,
        .io_ns = now + 40 * std.time.ns_per_ms,
        .cleanup_ns = now + 100 * std.time.ns_per_ms,
    };
    try std.testing.expectEqual(@as(c_int, 8), try pollTimeoutMs(now, deadlines));
    try std.testing.expectEqual(
        @as(c_int, 0),
        try pollTimeoutMs(now, .{ .io_ns = now + 999_999 }),
    );
    try std.testing.expectEqual(
        @as(c_int, 0),
        try pollTimeoutMs(now, .{ .control_ns = now }),
    );
    try std.testing.expectEqual(
        @as(c_int, -1),
        try pollTimeoutMs(now, .{}),
    );
}

test "p5c3c-3b poll timeout rejects invalid clock and deadline" {
    try std.testing.expectError(error.InvalidClock, pollTimeoutMs(-1, .{}));
    try std.testing.expectError(
        error.InvalidDeadline,
        pollTimeoutMs(10, .{ .chord_ns = -1 }),
    );
}

test "p5c3c-3b per-turn budgets match the normative transport bounds" {
    try std.testing.expectEqual(@as(usize, 1024 * 1024), socket_rx_budget_bytes);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), socket_tx_budget_bytes);
    try std.testing.expectEqual(@as(usize, 64), socket_rx_budget_frames);
    try std.testing.expectEqual(@as(usize, 64), socket_tx_budget_frames);
    try std.testing.expectEqual(@as(usize, 64 * 1024), stdin_budget_bytes);
    try std.testing.expectEqual(@as(usize, 64 * 1024), stdout_budget_bytes);
}
