//! External session-host pump policy and closed state DTOs.
//!
//! This module deliberately knows nothing about file descriptors, MRSH framing, JSON, allocators,
//! or the inbox ledger. Keeping the turn decision pure lets socket adapters and deterministic tests
//! share one deadline/priority policy without creating a second transport implementation.

const std = @import("std");
const external_recovery_types = @import("external_recovery_types.zig");

pub const max_interrupt_retries_per_direction: u8 = 8;

pub const TurnInput = struct {
    readable: bool,
    writable: bool,
    now_ns: i128,
};

pub const FdDisposition = enum {
    already_closed,
    owner_cleanup,
};

pub const TerminalReason = enum {
    eof,
    socket_error,
    protocol_error,
    resource_exhausted,
    request_id_exhausted,
    deadline_exceeded,
    revoked,
    runtime_ended,
    invariant_failure,
};

pub const ExternalPumpTerminal = struct {
    reason: TerminalReason,
    fd_disposition: FdDisposition,
};

pub const TurnResult = struct {
    rx_bytes: usize = 0,
    rx_read_bytes: usize = 0,
    rx_frames: usize = 0,
    tx_bytes: usize = 0,
    tx_frames: usize = 0,
    read_interest: bool = false,
    write_interest: bool = false,
    immediate_rx: bool = false,
    authority_clear: bool = false,
    control_ready: bool = false,
    inherited_work_ready: bool = false,
    terminal: ?ExternalPumpTerminal = null,
    next_deadline_ns: ?i128 = null,
};

pub const RequestIdState = @import("request_id_state.zig").State;

pub const RecoveryOrigin = external_recovery_types.Origin;
pub const RecoveryKey = external_recovery_types.Key;
pub const RecoveryMarkResult = external_recovery_types.MarkResult;

pub const PollHint = struct {
    immediate: bool,
    next_deadline_ns: ?i128,
};

pub const RecoveryContext = struct {
    epoch: u64,
    deadline_ns: i128,
};

pub const AwaitingSnapshot = struct {
    context: RecoveryContext,
    expected_token_generation: u64,
};

pub const HostRecoveryPhase = union(enum) {
    ack_unadmitted: RecoveryContext,
    ack_queued: RecoveryContext,
    awaiting_snapshot: AwaitingSnapshot,
    applied_pending: AwaitingSnapshot,
};

pub const ClientRecoveryPhase = union(enum) {
    control_wait: RecoveryContext,
    control_in_flight: RecoveryContext,
    awaiting_snapshot: AwaitingSnapshot,
    applied_pending: AwaitingSnapshot,
};

pub const ControlKind = enum {
    resize,
    resync,
};

pub const InFlightControlState = struct {
    kind: ControlKind,
    target_stream_id: u64,
    expected_controller_generation: u64,
    request_id: u64,
    deadline_ns: i128,
    tx_fully_sent: bool = false,
};

pub const AuthorityState = union(enum) {
    valid,
    control: InFlightControlState,
    host_recovery: HostRecoveryPhase,
    client_recovery: ClientRecoveryPhase,
};

pub const ExternalPumpState = union(enum) {
    constructing,
    adopting,
    active: AuthorityState,
    terminal: ExternalPumpTerminal,
};

pub const RecoveryTrigger = enum {
    local_overflow,
    host_invalidated,
    fresh_commit,
};

/// Evidence owned by f1/f2 and consumed by the recovery reducer. Keeping this semantic enum here
/// lets e-core close the collision table without inventing TX offsets or response ownership.
pub const ControlProgress = enum {
    none,
    offset_zero_unsent,
    partial,
    fully_sent,
    response_wait,
};

pub const RecoveryDisposition = enum {
    no_op,
    entered,
    promoted_to_host,
    committed,
    terminal,
};

pub const RecoveryTransitionInput = struct {
    state: AuthorityState,
    trigger: RecoveryTrigger,
    control: ControlProgress = .none,
    now_ns: i128,
    /// Supplied only for a new valid→recovery transition. The caller checked epoch increment and
    /// absolute-deadline arithmetic before asking this allocation-free reducer to publish a plan.
    new_context: ?RecoveryContext = null,
};

pub const RecoveryTransitionPlan = struct {
    disposition: RecoveryDisposition,
    next: AuthorityState,
    drop_backlog: bool = false,
    cancel_control: bool = false,
};

fn terminalRecoveryPlan() RecoveryTransitionPlan {
    return .{
        .disposition = .terminal,
        // The caller maps this closed disposition to ExternalPumpState.terminal. `next` remains a
        // non-authoritative placeholder so no terminal branch can accidentally clear a gate.
        .next = .valid,
    };
}

fn enterRecovery(
    origin: RecoveryOrigin,
    context: RecoveryContext,
    cancel_control: bool,
) RecoveryTransitionPlan {
    if (context.epoch == 0) return terminalRecoveryPlan();
    return .{
        .disposition = .entered,
        .next = switch (origin) {
            .host => .{ .host_recovery = .{ .ack_unadmitted = context } },
            .client => .{ .client_recovery = .{ .control_wait = context } },
        },
        .drop_backlog = true,
        .cancel_control = cancel_control,
    };
}

fn recoveryContext(state: AuthorityState) ?RecoveryContext {
    return switch (state) {
        .valid, .control => null,
        .host_recovery => |phase| switch (phase) {
            .ack_unadmitted => |context| context,
            .ack_queued => |context| context,
            .awaiting_snapshot => |waiting| waiting.context,
            .applied_pending => |waiting| waiting.context,
        },
        .client_recovery => |phase| switch (phase) {
            .control_wait => |context| context,
            .control_in_flight => |context| context,
            .awaiting_snapshot => |waiting| waiting.context,
            .applied_pending => |waiting| waiting.context,
        },
    };
}

pub fn recoveryDeadline(state: AuthorityState) ?i128 {
    const context = recoveryContext(state) orelse return null;
    return context.deadline_ns;
}

fn planFreshRecoveryCommit(input: RecoveryTransitionInput) RecoveryTransitionPlan {
    const waiting = switch (input.state) {
        .host_recovery => |phase| switch (phase) {
            .applied_pending => |value| value,
            else => return terminalRecoveryPlan(),
        },
        .client_recovery => |phase| switch (phase) {
            .applied_pending => |value| value,
            else => return terminalRecoveryPlan(),
        },
        else => return terminalRecoveryPlan(),
    };
    if (input.control != .none or input.now_ns >= waiting.context.deadline_ns)
        return terminalRecoveryPlan();
    return .{
        .disposition = .committed,
        .next = .valid,
    };
}

/// Closed allocation-free interpretation of the normative 2b2e collision table. It never mutates
/// queues or controls; the storage layer must seal the returned actions with its cleanup aggregate
/// and commit them in one no-callback suffix.
pub fn planRecoveryTransition(
    input: RecoveryTransitionInput,
) RecoveryTransitionPlan {
    if (input.trigger == .fresh_commit) return planFreshRecoveryCommit(input);

    switch (input.state) {
        .valid, .control => {
            if (input.new_context == null) return terminalRecoveryPlan();
            const cancel = switch (input.control) {
                .none => false,
                .offset_zero_unsent => true,
                .partial, .fully_sent, .response_wait => return terminalRecoveryPlan(),
            };
            return enterRecovery(
                if (input.trigger == .host_invalidated) .host else .client,
                input.new_context.?,
                cancel,
            );
        },
        .host_recovery => {
            // Both triggers are duplicates once host recovery owns the epoch.
            return .{
                .disposition = .no_op,
                .next = input.state,
            };
        },
        .client_recovery => |phase| {
            if (input.trigger == .local_overflow) {
                return .{
                    .disposition = .no_op,
                    .next = input.state,
                };
            }
            const context = recoveryContext(input.state) orelse
                return terminalRecoveryPlan();
            const promotable = switch (phase) {
                .control_wait => input.control == .none or
                    input.control == .offset_zero_unsent,
                .control_in_flight => input.control == .offset_zero_unsent,
                .awaiting_snapshot, .applied_pending => false,
            };
            if (!promotable) return terminalRecoveryPlan();
            var plan = enterRecovery(
                .host,
                context,
                input.control == .offset_zero_unsent,
            );
            plan.disposition = .promoted_to_host;
            return plan;
        },
    }
}

pub const ParserReadiness = enum {
    empty,
    incomplete,
    complete_or_error,
};

pub const PolicyInput = struct {
    turn: TurnInput,
    parser: ParserReadiness,
    socket_rx_drained: bool,
    rx_frame_budget_exhausted: bool = false,
    rx_read_budget_exhausted: bool = false,
    tx_pending: bool = false,
    control_ready: bool = false,
    inherited_blocker: bool = false,
    terminal: ?ExternalPumpTerminal = null,
    deadlines: [5]?i128 = .{null} ** 5,
};

/// Decide scheduling only. Mechanics later fill byte/frame counters after performing bounded I/O.
pub fn decide(input: PolicyInput) TurnResult {
    var result = TurnResult{
        .read_interest = input.terminal == null,
        .control_ready = input.control_ready,
        .terminal = input.terminal,
        .next_deadline_ns = minimumDeadline(input.deadlines),
    };
    if (result.terminal != null) {
        result.read_interest = false;
        result.control_ready = false;
        return result;
    }
    if (result.next_deadline_ns) |deadline| {
        if (input.turn.now_ns >= deadline) {
            result.terminal = .{
                .reason = .deadline_exceeded,
                .fd_disposition = .owner_cleanup,
            };
            result.read_interest = false;
            result.write_interest = false;
            result.control_ready = false;
            return result;
        }
    }

    if (input.inherited_blocker) {
        result.read_interest = false;
        result.control_ready = false;
        result.inherited_work_ready = true;
        return result;
    }

    result.immediate_rx = input.rx_frame_budget_exhausted or
        input.rx_read_budget_exhausted or
        input.parser == .complete_or_error;
    if (result.immediate_rx) result.read_interest = false;
    result.authority_clear = input.socket_rx_drained and
        input.parser == .empty and
        !input.rx_frame_budget_exhausted and
        !input.rx_read_budget_exhausted;
    result.write_interest = input.tx_pending and result.authority_clear;
    if (!result.authority_clear) result.control_ready = false;
    return result;
}

pub fn minimumDeadline(deadlines: [5]?i128) ?i128 {
    var minimum: ?i128 = null;
    for (deadlines) |candidate| {
        const value = candidate orelse continue;
        if (minimum == null or value < minimum.?) minimum = value;
    }
    return minimum;
}

test "client pump request IDs use max exactly once and never wrap to zero" {
    var ordinary = try RequestIdState.fromNext(41);
    const first = try ordinary.prepare();
    try std.testing.expectEqual(@as(u64, 41), first.id);
    // A failed encode/admission leaves the source state unchanged.
    try std.testing.expectEqual(@as(u64, 41), (try ordinary.prepare()).id);
    try ordinary.commit(first);
    const second = try ordinary.prepare();
    try std.testing.expectEqual(@as(u64, 42), second.id);
    try ordinary.commit(second);

    var last = try RequestIdState.fromNext(std.math.maxInt(u64));
    const final = try last.prepare();
    try std.testing.expectEqual(std.math.maxInt(u64), final.id);
    try last.commit(final);
    try std.testing.expectError(error.Exhausted, last.prepare());
    try std.testing.expectError(error.InvalidZero, RequestIdState.fromNext(0));

    var forged_zero = RequestIdState{ .available = 0 };
    try std.testing.expectError(error.InvalidState, forged_zero.prepare());
    var forged_max = RequestIdState{ .available = std.math.maxInt(u64) };
    try std.testing.expectError(error.InvalidState, forged_max.prepare());

    var stale = try RequestIdState.fromNext(8);
    const prepared = try stale.prepare();
    stale = try RequestIdState.fromNext(9);
    try std.testing.expectError(error.StaleState, stale.commit(prepared));

    var forged = try RequestIdState.fromNext(1);
    const canonical = try forged.prepare();
    var bad_id = canonical;
    bad_id.id = 0;
    try std.testing.expectError(error.InvalidPrepared, forged.commit(bad_id));
    var bad_next = canonical;
    bad_next.next = .{ .available = 0 };
    try std.testing.expectError(error.InvalidPrepared, forged.commit(bad_next));
    try std.testing.expect(std.meta.eql(try RequestIdState.fromNext(1), forged));
}

test "client pump preserves recovery origin in every snapshot phase" {
    const waiting = AwaitingSnapshot{
        .context = .{ .epoch = 7, .deadline_ns = 30 },
        .expected_token_generation = 9,
    };
    const host = AuthorityState{ .host_recovery = .{ .awaiting_snapshot = waiting } };
    const client = AuthorityState{ .client_recovery = .{ .applied_pending = waiting } };
    try std.testing.expect(host == .host_recovery);
    try std.testing.expect(client == .client_recovery);
    try std.testing.expectEqual(@as(u64, 7), host.host_recovery.awaiting_snapshot.context.epoch);
    try std.testing.expectEqual(@as(u64, 7), client.client_recovery.applied_pending.context.epoch);
}

test "recovery reducer enters from valid and rejects unsafe unrelated controls" {
    const context = RecoveryContext{ .epoch = 4, .deadline_ns = 100 };
    const client = planRecoveryTransition(.{
        .state = .valid,
        .trigger = .local_overflow,
        .now_ns = 20,
        .new_context = context,
    });
    try std.testing.expectEqual(RecoveryDisposition.entered, client.disposition);
    try std.testing.expect(client.next == .client_recovery);
    try std.testing.expect(std.meta.eql(
        context,
        client.next.client_recovery.control_wait,
    ));
    try std.testing.expect(client.drop_backlog);
    try std.testing.expect(!client.cancel_control);

    const host = planRecoveryTransition(.{
        .state = .valid,
        .trigger = .host_invalidated,
        .control = .offset_zero_unsent,
        .now_ns = 20,
        .new_context = context,
    });
    try std.testing.expectEqual(RecoveryDisposition.entered, host.disposition);
    try std.testing.expect(host.next == .host_recovery);
    try std.testing.expect(host.cancel_control);

    for ([_]ControlProgress{ .partial, .fully_sent, .response_wait }) |progress| {
        const terminal = planRecoveryTransition(.{
            .state = .valid,
            .trigger = .host_invalidated,
            .control = progress,
            .now_ns = 20,
            .new_context = context,
        });
        try std.testing.expectEqual(
            RecoveryDisposition.terminal,
            terminal.disposition,
        );
        try std.testing.expect(!terminal.drop_backlog);
        try std.testing.expect(!terminal.cancel_control);
    }
}

test "recovery reducer keeps duplicate origin epoch and deadline immutable" {
    const context = RecoveryContext{ .epoch = 8, .deadline_ns = 300 };
    const waiting = AwaitingSnapshot{
        .context = context,
        .expected_token_generation = 17,
    };
    const states = [_]AuthorityState{
        .{ .host_recovery = .{ .ack_unadmitted = context } },
        .{ .host_recovery = .{ .ack_queued = context } },
        .{ .host_recovery = .{ .awaiting_snapshot = waiting } },
        .{ .host_recovery = .{ .applied_pending = waiting } },
        .{ .client_recovery = .{ .control_wait = context } },
        .{ .client_recovery = .{ .control_in_flight = context } },
        .{ .client_recovery = .{ .awaiting_snapshot = waiting } },
        .{ .client_recovery = .{ .applied_pending = waiting } },
    };
    for (states) |state| {
        const trigger: RecoveryTrigger = if (state == .host_recovery)
            .host_invalidated
        else
            .local_overflow;
        const plan = planRecoveryTransition(.{
            .state = state,
            .trigger = trigger,
            .now_ns = 250,
            .new_context = .{ .epoch = 99, .deadline_ns = 999 },
        });
        try std.testing.expectEqual(RecoveryDisposition.no_op, plan.disposition);
        try std.testing.expect(std.meta.eql(state, plan.next));
        try std.testing.expect(!plan.drop_backlog);
        try std.testing.expect(!plan.cancel_control);
    }
}

test "host invalidated promotes only cancellable client recovery control" {
    const context = RecoveryContext{ .epoch = 11, .deadline_ns = 500 };
    const waiting = AwaitingSnapshot{
        .context = context,
        .expected_token_generation = 23,
    };
    const promotable = [_]struct {
        state: AuthorityState,
        progress: ControlProgress,
        cancel: bool,
    }{
        .{
            .state = .{ .client_recovery = .{ .control_wait = context } },
            .progress = .none,
            .cancel = false,
        },
        .{
            .state = .{ .client_recovery = .{ .control_wait = context } },
            .progress = .offset_zero_unsent,
            .cancel = true,
        },
        .{
            .state = .{ .client_recovery = .{ .control_in_flight = context } },
            .progress = .offset_zero_unsent,
            .cancel = true,
        },
    };
    for (promotable) |case| {
        const plan = planRecoveryTransition(.{
            .state = case.state,
            .trigger = .host_invalidated,
            .control = case.progress,
            .now_ns = 100,
        });
        try std.testing.expectEqual(
            RecoveryDisposition.promoted_to_host,
            plan.disposition,
        );
        try std.testing.expect(plan.next == .host_recovery);
        try std.testing.expect(std.meta.eql(
            context,
            plan.next.host_recovery.ack_unadmitted,
        ));
        try std.testing.expectEqual(case.cancel, plan.cancel_control);
    }

    const forbidden = [_]struct {
        state: AuthorityState,
        progress: ControlProgress,
    }{
        .{
            .state = .{ .client_recovery = .{ .control_in_flight = context } },
            .progress = .partial,
        },
        .{
            .state = .{ .client_recovery = .{ .control_in_flight = context } },
            .progress = .fully_sent,
        },
        .{
            .state = .{ .client_recovery = .{ .control_in_flight = context } },
            .progress = .response_wait,
        },
        .{
            .state = .{ .client_recovery = .{ .awaiting_snapshot = waiting } },
            .progress = .none,
        },
        .{
            .state = .{ .client_recovery = .{ .applied_pending = waiting } },
            .progress = .none,
        },
    };
    for (forbidden) |case| {
        const plan = planRecoveryTransition(.{
            .state = case.state,
            .trigger = .host_invalidated,
            .control = case.progress,
            .now_ns = 100,
        });
        try std.testing.expectEqual(
            RecoveryDisposition.terminal,
            plan.disposition,
        );
        try std.testing.expect(!plan.drop_backlog);
        try std.testing.expect(!plan.cancel_control);
    }
}

test "fresh recovery commit is deadline-first and phase exact" {
    const waiting = AwaitingSnapshot{
        .context = .{ .epoch = 5, .deadline_ns = 100 },
        .expected_token_generation = 19,
    };
    for ([_]AuthorityState{
        .{ .host_recovery = .{ .applied_pending = waiting } },
        .{ .client_recovery = .{ .applied_pending = waiting } },
    }) |state| {
        const before = planRecoveryTransition(.{
            .state = state,
            .trigger = .fresh_commit,
            .now_ns = 99,
        });
        try std.testing.expectEqual(RecoveryDisposition.committed, before.disposition);
        try std.testing.expect(before.next == .valid);

        for ([_]i128{ 100, 101 }) |now_ns| {
            const expired = planRecoveryTransition(.{
                .state = state,
                .trigger = .fresh_commit,
                .now_ns = now_ns,
            });
            try std.testing.expectEqual(
                RecoveryDisposition.terminal,
                expired.disposition,
            );
        }
    }

    const stale_phase = planRecoveryTransition(.{
        .state = .{ .host_recovery = .{ .awaiting_snapshot = waiting } },
        .trigger = .fresh_commit,
        .now_ns = 99,
    });
    try std.testing.expectEqual(
        RecoveryDisposition.terminal,
        stale_phase.disposition,
    );
}

test "client pump deadline is checked before readable or writable readiness" {
    const result = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 50 },
        .parser = .complete_or_error,
        .socket_rx_drained = false,
        .tx_pending = true,
        .control_ready = true,
        .deadlines = .{ 90, 50, null, 70, null },
    });
    try std.testing.expectEqual(@as(?i128, 50), result.next_deadline_ns);
    try std.testing.expectEqual(TerminalReason.deadline_exceeded, result.terminal.?.reason);
    try std.testing.expect(!result.write_interest);
    try std.testing.expect(!result.control_ready);
    try std.testing.expect(!result.authority_clear);

    const before = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 49 },
        .parser = .empty,
        .socket_rx_drained = true,
        .tx_pending = true,
        .deadlines = .{ 50, null, null, null, null },
    });
    try std.testing.expect(before.terminal == null);
    try std.testing.expect(before.authority_clear);
    try std.testing.expect(before.write_interest);

    const after = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 51 },
        .parser = .empty,
        .socket_rx_drained = true,
        .tx_pending = true,
        .deadlines = .{ 50, null, null, null, null },
    });
    try std.testing.expectEqual(TerminalReason.deadline_exceeded, after.terminal.?.reason);
    try std.testing.expect(!after.read_interest);
    try std.testing.expect(!after.write_interest);
}

test "client pump terminal and deadline dominate inherited blockers" {
    const terminal = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 40 },
        .parser = .complete_or_error,
        .socket_rx_drained = false,
        .inherited_blocker = true,
        .terminal = .{
            .reason = .revoked,
            .fd_disposition = .owner_cleanup,
        },
    });
    try std.testing.expectEqual(TerminalReason.revoked, terminal.terminal.?.reason);
    try std.testing.expect(!terminal.inherited_work_ready);

    const deadline = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 40 },
        .parser = .complete_or_error,
        .socket_rx_drained = false,
        .inherited_blocker = true,
        .deadlines = .{ 40, null, null, null, null },
    });
    try std.testing.expectEqual(
        TerminalReason.deadline_exceeded,
        deadline.terminal.?.reason,
    );
    try std.testing.expect(!deadline.inherited_work_ready);
}

test "client pump inherited blocker suppresses parser socket and lower authority" {
    const result = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 39 },
        .parser = .complete_or_error,
        .socket_rx_drained = true,
        .rx_frame_budget_exhausted = true,
        .tx_pending = true,
        .control_ready = true,
        .inherited_blocker = true,
        .deadlines = .{ 40, null, null, null, null },
    });
    try std.testing.expect(result.terminal == null);
    try std.testing.expect(result.inherited_work_ready);
    try std.testing.expect(!result.immediate_rx);
    try std.testing.expect(!result.read_interest);
    try std.testing.expect(!result.write_interest);
    try std.testing.expect(!result.control_ready);
    try std.testing.expect(!result.authority_clear);
}

test "client pump only clears authority after would-block and an empty parser" {
    const empty = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 1 },
        .parser = .empty,
        .socket_rx_drained = true,
        .tx_pending = true,
        .control_ready = true,
    });
    try std.testing.expect(empty.authority_clear);
    try std.testing.expect(empty.control_ready);

    const partial = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 1 },
        .parser = .incomplete,
        .socket_rx_drained = true,
        .tx_pending = true,
        .control_ready = true,
    });
    try std.testing.expect(!partial.authority_clear);
    try std.testing.expect(!partial.immediate_rx);
    try std.testing.expect(partial.read_interest);
    try std.testing.expect(!partial.control_ready);
    try std.testing.expect(!partial.write_interest);

    const backlog = decide(.{
        .turn = .{ .readable = false, .writable = true, .now_ns = 1 },
        .parser = .complete_or_error,
        .socket_rx_drained = true,
    });
    try std.testing.expect(!backlog.authority_clear);
    try std.testing.expect(backlog.immediate_rx);
    try std.testing.expect(!backlog.read_interest);

    const frame_budget = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 1 },
        .parser = .empty,
        .socket_rx_drained = true,
        .rx_frame_budget_exhausted = true,
        .tx_pending = true,
    });
    try std.testing.expect(frame_budget.immediate_rx);
    try std.testing.expect(!frame_budget.authority_clear);
    try std.testing.expect(!frame_budget.write_interest);
    try std.testing.expect(!frame_budget.read_interest);

    const read_budget = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 1 },
        .parser = .empty,
        .socket_rx_drained = true,
        .rx_read_budget_exhausted = true,
        .tx_pending = true,
    });
    try std.testing.expect(read_budget.immediate_rx);
    try std.testing.expect(!read_budget.authority_clear);
    try std.testing.expect(!read_budget.write_interest);
    try std.testing.expect(!read_budget.read_interest);
}

test "client pump terminal outcomes expose no poll interest" {
    const existing = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 1 },
        .parser = .empty,
        .socket_rx_drained = true,
        .tx_pending = true,
        .control_ready = true,
        .terminal = .{ .reason = .revoked, .fd_disposition = .owner_cleanup },
    });
    try std.testing.expect(!existing.read_interest);
    try std.testing.expect(!existing.write_interest);
    try std.testing.expect(!existing.control_ready);

    const expired = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 2 },
        .parser = .empty,
        .socket_rx_drained = true,
        .tx_pending = true,
        .control_ready = true,
        .deadlines = .{ 2, null, null, null, null },
    });
    try std.testing.expect(!expired.read_interest);
    try std.testing.expect(!expired.write_interest);
    try std.testing.expect(!expired.control_ready);
}
