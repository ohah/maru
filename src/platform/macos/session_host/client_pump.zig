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
    immediate_tx: bool = false,
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

pub const RecoverySnapshotBindingDisposition = enum {
    bound,
    terminal,
};

pub const RecoverySnapshotBindingPlan = struct {
    disposition: RecoverySnapshotBindingDisposition,
    next: AuthorityState,
};

pub const RecoverySnapshotCandidate = struct {
    origin: RecoveryOrigin,
    recovery_epoch: u64,
    is_snapshot: bool,
    start_absolute: u64,
    end_absolute: u64,
    committed_token_generation: u64,
};

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
    recovery_barrier_absolute: u64,
};

pub const SnapshotInFlight = struct {
    /// Bound means a ledger token exists; the consumer may not have borrowed its lease yet.
    context: RecoveryContext,
    recovery_barrier_absolute: u64,
    expected_token_generation: u64,
};

pub const HostRecoveryPhase = union(enum) {
    ack_unadmitted: RecoveryContext,
    ack_queued: RecoveryContext,
    awaiting_snapshot: AwaitingSnapshot,
    snapshot_in_flight: SnapshotInFlight,
    applied_pending: SnapshotInFlight,
};

pub const ClientRecoveryPhase = union(enum) {
    control_wait: RecoveryContext,
    control_in_flight: RecoveryContext,
    awaiting_snapshot: AwaitingSnapshot,
    snapshot_in_flight: SnapshotInFlight,
    applied_pending: SnapshotInFlight,
};

pub const ControlKind = enum {
    resize,
    resync,
    detach,
    declare_viewport,

    /// **controller 자격이 있어야 보낼 수 있는가.** observer 도 보낼 수 있는 것이 둘이다 —
    /// 떨어지겠다는 `detach`, 그리고 자기가 그릴 수 있는 격자를 알리는 `declare_viewport`
    /// (S11-6: client 는 «알릴» 뿐 mutation 을 부르지 않는다). 부정 조건을 늘려 적지 않고
    /// 여기서 한 번에 답한다 — 갈래가 늘 때마다 흩어진 `!= .detach` 를 전부 찾아야 하면
    /// 하나를 빠뜨린다.
    pub fn requiresController(self: ControlKind) bool {
        return switch (self) {
            .resize, .resync => true,
            .detach, .declare_viewport => false,
        };
    }
};

pub const AuthorityState = union(enum) {
    valid,
    host_recovery: HostRecoveryPhase,
    client_recovery: ClientRecoveryPhase,
};

pub const ExternalPumpState = union(enum) {
    constructing,
    adopting,
    active: AuthorityState,
    terminal: ExternalPumpTerminal,
};

/// Binds the first accepted recovery snapshot to the actual ledger token generation.
///
/// The control request cannot know this generation. The storage layer may apply this plan only in
/// the no-callback suffix of the ledger commit that created the token.
pub fn planRecoverySnapshotBinding(
    state: AuthorityState,
    candidate: RecoverySnapshotCandidate,
) RecoverySnapshotBindingPlan {
    if (!candidate.is_snapshot or candidate.recovery_epoch == 0 or
        candidate.committed_token_generation == 0 or
        candidate.end_absolute <= candidate.start_absolute)
        return .{ .disposition = .terminal, .next = state };
    return switch (state) {
        .host_recovery => |phase| switch (phase) {
            .awaiting_snapshot => |waiting| if (candidate.origin == .host and
                candidate.recovery_epoch == waiting.context.epoch and
                candidate.start_absolute >= waiting.recovery_barrier_absolute)
                .{
                    .disposition = .bound,
                    .next = .{ .host_recovery = .{ .snapshot_in_flight = .{
                        .context = waiting.context,
                        .recovery_barrier_absolute = waiting.recovery_barrier_absolute,
                        .expected_token_generation = candidate.committed_token_generation,
                    } } },
                }
            else
                .{ .disposition = .terminal, .next = state },
            else => .{ .disposition = .terminal, .next = state },
        },
        .client_recovery => |phase| switch (phase) {
            .awaiting_snapshot => |waiting| if (candidate.origin == .client and
                candidate.recovery_epoch == waiting.context.epoch and
                candidate.start_absolute >= waiting.recovery_barrier_absolute)
                .{
                    .disposition = .bound,
                    .next = .{ .client_recovery = .{ .snapshot_in_flight = .{
                        .context = waiting.context,
                        .recovery_barrier_absolute = waiting.recovery_barrier_absolute,
                        .expected_token_generation = candidate.committed_token_generation,
                    } } },
                }
            else
                .{ .disposition = .terminal, .next = state },
            else => .{ .disposition = .terminal, .next = state },
        },
        .valid => .{ .disposition = .terminal, .next = state },
    };
}

pub const RecoveryTrigger = enum {
    local_overflow,
    host_invalidated,
    resync_ack,
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

/// Mutually composable causes already observed and sealed by the current RX turn. This is a
/// semantic DTO: transport adapters must not infer protocol or revoke state from raw bytes here.
pub const WholeTurnCauses = struct {
    deadline_expired: bool = false,
    backwards_clock: bool = false,
    invariant_or_corruption: bool = false,
    resource_exhausted: bool = false,
    protocol_violation: bool = false,
    exact_revoke: bool = false,
    /// A turn-start readiness hint. It suppresses TX immediately but becomes EOF only after the
    /// bounded RX drain reports completion.
    peer_hup_hint: bool = false,
    peer_hup_drain_complete: bool = false,
    transport: TransportTerminal = .none,
};

pub const TransportTerminal = enum {
    none,
    eof,
    socket_error,
};

pub const RevokeIntegrationAction = enum {
    cancel_queued,
    cleanup_completed,
    poison_close,
    success_candidate,
    continue_bounded_rx,
};

pub const RevokeIntegrationInput = struct {
    causes: WholeTurnCauses,
    completed_present: bool,
    control: F3ControlProgress,
};

pub const F3ControlProgress = enum {
    none,
    queued,
    partial,
    fully_sent,
    response_wait,
    missing,
    invalid,
};

pub const RevokeIntegrationPlan = struct {
    action: RevokeIntegrationAction,
    terminal: ?ExternalPumpTerminal,
    suppress_tx: bool = false,
    bounded_rx_required: bool = false,
};

fn terminalForWholeTurn(causes: WholeTurnCauses) ?ExternalPumpTerminal {
    const reason: ?TerminalReason = if (causes.deadline_expired)
        .deadline_exceeded
    else if (causes.backwards_clock)
        .invariant_failure
    else if (causes.invariant_or_corruption)
        .invariant_failure
    else if (causes.resource_exhausted)
        .resource_exhausted
    else if (causes.protocol_violation)
        .protocol_error
    else if (causes.exact_revoke)
        .revoked
    else switch (causes.transport) {
        .none => if (causes.peer_hup_hint and causes.peer_hup_drain_complete) .eof else null,
        .eof => .eof,
        .socket_error => .socket_error,
    };
    return if (reason) |value| .{
        .reason = value,
        .fd_disposition = .owner_cleanup,
    } else null;
}

/// Allocation-free f3a policy. The caller supplies only causes already observed before traversal
/// stopped; in particular, bytes after an OOM are not candidates. This function chooses ownership
/// work but never mutates the TX queue, correlation owner, completed payload, or authority.
pub fn planRevokeIntegration(input: RevokeIntegrationInput) RevokeIntegrationPlan {
    var causes = input.causes;
    // A completed owner exists only after the correlated request descriptor retired. Mixing that
    // owner with any live/missing/invalid TX progress is sealed corruption, not a terminal reason
    // that may be laundered into a normal revoke/EOF cleanup.
    if ((input.completed_present and input.control != .none) or
        (causes.peer_hup_drain_complete and !causes.peer_hup_hint))
        causes.invariant_or_corruption = true;
    const terminal = terminalForWholeTurn(causes);
    const draining_hup = causes.peer_hup_hint and
        !causes.peer_hup_drain_complete and terminal == null;
    if (terminal == null) return .{
        .action = if (draining_hup)
            .continue_bounded_rx
        else if (input.completed_present)
            .success_candidate
        else
            .poison_close,
        .terminal = if (input.completed_present or draining_hup) null else .{
            .reason = .invariant_failure,
            .fd_disposition = .owner_cleanup,
        },
        .suppress_tx = draining_hup or !input.completed_present,
        .bounded_rx_required = draining_hup,
    };

    if (input.completed_present) return .{
        .action = .cleanup_completed,
        .terminal = terminal,
        .suppress_tx = true,
    };

    if (terminal.?.reason == .revoked) return switch (input.control) {
        .none, .queued => .{
            .action = .cancel_queued,
            .terminal = terminal,
            .suppress_tx = true,
        },
        .partial, .fully_sent, .response_wait, .missing, .invalid => .{
            .action = .poison_close,
            .terminal = .{
                .reason = .protocol_error,
                .fd_disposition = .owner_cleanup,
            },
            .suppress_tx = true,
        },
    };

    return .{
        .action = .poison_close,
        .terminal = terminal,
        .suppress_tx = true,
    };
}

test "f3a whole-turn precedence is total and deadline first" {
    const all = planRevokeIntegration(.{
        .causes = .{
            .deadline_expired = true,
            .backwards_clock = true,
            .invariant_or_corruption = true,
            .resource_exhausted = true,
            .protocol_violation = true,
            .exact_revoke = true,
            .transport = .socket_error,
        },
        .completed_present = true,
        .control = .response_wait,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.cleanup_completed, all.action);
    try std.testing.expectEqual(TerminalReason.deadline_exceeded, all.terminal.?.reason);

    const ordered = [_]struct {
        causes: WholeTurnCauses,
        reason: TerminalReason,
    }{
        .{ .causes = .{ .backwards_clock = true }, .reason = .invariant_failure },
        .{ .causes = .{ .invariant_or_corruption = true }, .reason = .invariant_failure },
        .{ .causes = .{ .resource_exhausted = true }, .reason = .resource_exhausted },
        .{ .causes = .{ .protocol_violation = true }, .reason = .protocol_error },
        .{ .causes = .{ .exact_revoke = true }, .reason = .revoked },
        .{ .causes = .{ .transport = .eof }, .reason = .eof },
        .{ .causes = .{ .transport = .socket_error }, .reason = .socket_error },
    };
    for (ordered) |case| {
        const plan = planRevokeIntegration(.{
            .causes = case.causes,
            .completed_present = true,
            .control = .none,
        });
        try std.testing.expectEqual(case.reason, plan.terminal.?.reason);
        try std.testing.expectEqual(FdDisposition.owner_cleanup, plan.terminal.?.fd_disposition);
    }
}

test "f3a revoke cancels only exact unsent control and otherwise fails closed" {
    const progresses = [_]F3ControlProgress{
        .none,
        .queued,
        .partial,
        .fully_sent,
        .response_wait,
        .missing,
        .invalid,
    };
    for (progresses) |progress| {
        const plan = planRevokeIntegration(.{
            .causes = .{ .exact_revoke = true },
            .completed_present = false,
            .control = progress,
        });
        switch (progress) {
            .none, .queued => {
                try std.testing.expectEqual(RevokeIntegrationAction.cancel_queued, plan.action);
                try std.testing.expectEqual(TerminalReason.revoked, plan.terminal.?.reason);
            },
            .partial, .fully_sent, .response_wait, .missing, .invalid => {
                try std.testing.expectEqual(RevokeIntegrationAction.poison_close, plan.action);
                try std.testing.expectEqual(TerminalReason.protocol_error, plan.terminal.?.reason);
            },
        }
    }
}

test "f3a HUP suppresses TX while bounded RX decides stronger cause" {
    const draining = planRevokeIntegration(.{
        .causes = .{ .peer_hup_hint = true },
        .completed_present = false,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.continue_bounded_rx, draining.action);
    try std.testing.expectEqual(@as(?ExternalPumpTerminal, null), draining.terminal);
    try std.testing.expect(draining.suppress_tx);
    try std.testing.expect(draining.bounded_rx_required);

    const drained = planRevokeIntegration(.{
        .causes = .{ .peer_hup_hint = true, .peer_hup_drain_complete = true },
        .completed_present = false,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.poison_close, drained.action);
    try std.testing.expectEqual(TerminalReason.eof, drained.terminal.?.reason);
    try std.testing.expect(drained.suppress_tx);

    const stronger = planRevokeIntegration(.{
        .causes = .{ .peer_hup_hint = true, .protocol_violation = true },
        .completed_present = true,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.cleanup_completed, stronger.action);
    try std.testing.expectEqual(TerminalReason.protocol_error, stronger.terminal.?.reason);
}

test "f3a pairwise candidate matrix preserves precedence for every control state" {
    const Candidate = enum {
        deadline,
        invariant,
        resource,
        protocol,
        revoke,
        eof,
        socket,
    };
    const candidates = [_]Candidate{
        .deadline,
        .invariant,
        .resource,
        .protocol,
        .revoke,
        .eof,
        .socket,
    };
    const reasons = [_]TerminalReason{
        .deadline_exceeded,
        .invariant_failure,
        .resource_exhausted,
        .protocol_error,
        .revoked,
        .eof,
        .socket_error,
    };
    const controls = [_]F3ControlProgress{
        .none,
        .queued,
        .partial,
        .fully_sent,
        .response_wait,
        .missing,
        .invalid,
    };
    for (candidates, 0..) |left, left_index| {
        for (candidates, 0..) |right, right_index| {
            var causes: WholeTurnCauses = .{};
            for ([_]Candidate{ left, right }) |candidate| switch (candidate) {
                .deadline => causes.deadline_expired = true,
                .invariant => causes.invariant_or_corruption = true,
                .resource => causes.resource_exhausted = true,
                .protocol => causes.protocol_violation = true,
                .revoke => causes.exact_revoke = true,
                .eof => causes.transport = .eof,
                .socket => if (causes.transport == .none) {
                    causes.transport = .socket_error;
                },
            };
            const expected_reason = reasons[@min(left_index, right_index)];
            for ([_]bool{ false, true }) |completed| {
                for (controls) |control| {
                    const plan = planRevokeIntegration(.{
                        .causes = causes,
                        .completed_present = completed,
                        .control = control,
                    });
                    if (completed) {
                        try std.testing.expectEqual(
                            RevokeIntegrationAction.cleanup_completed,
                            plan.action,
                        );
                        const completed_reason: TerminalReason = if (control != .none and
                            left_index != 0 and right_index != 0)
                            .invariant_failure
                        else
                            expected_reason;
                        try std.testing.expectEqual(completed_reason, plan.terminal.?.reason);
                        try std.testing.expect(plan.suppress_tx);
                    } else if (expected_reason == .revoked and
                        (control == .none or control == .queued))
                    {
                        try std.testing.expectEqual(
                            RevokeIntegrationAction.cancel_queued,
                            plan.action,
                        );
                        try std.testing.expectEqual(TerminalReason.revoked, plan.terminal.?.reason);
                        try std.testing.expect(plan.suppress_tx);
                    } else {
                        try std.testing.expectEqual(
                            RevokeIntegrationAction.poison_close,
                            plan.action,
                        );
                        const poison_reason: TerminalReason = if (expected_reason == .revoked)
                            .protocol_error
                        else
                            expected_reason;
                        try std.testing.expectEqual(poison_reason, plan.terminal.?.reason);
                        try std.testing.expect(plan.suppress_tx);
                    }
                }
            }
        }
    }
}

test "f3a completed payload cleanup dominates terminal and clean drain is candidate only" {
    const revoked = planRevokeIntegration(.{
        .causes = .{ .exact_revoke = true },
        .completed_present = true,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.cleanup_completed, revoked.action);
    try std.testing.expectEqual(TerminalReason.revoked, revoked.terminal.?.reason);

    const clean = planRevokeIntegration(.{
        .causes = .{},
        .completed_present = true,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.success_candidate, clean.action);
    try std.testing.expectEqual(@as(?ExternalPumpTerminal, null), clean.terminal);

    const impossible = planRevokeIntegration(.{
        .causes = .{},
        .completed_present = false,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.poison_close, impossible.action);
    try std.testing.expectEqual(TerminalReason.invariant_failure, impossible.terminal.?.reason);
}

test "f3a completed correlation and HUP DTO canonicality fail closed" {
    const invalid_progresses = [_]F3ControlProgress{
        .queued,
        .partial,
        .fully_sent,
        .response_wait,
        .missing,
        .invalid,
    };
    for (invalid_progresses) |control| {
        const clean = planRevokeIntegration(.{
            .causes = .{},
            .completed_present = true,
            .control = control,
        });
        try std.testing.expectEqual(RevokeIntegrationAction.cleanup_completed, clean.action);
        try std.testing.expectEqual(TerminalReason.invariant_failure, clean.terminal.?.reason);
        try std.testing.expect(clean.suppress_tx);

        const revoked = planRevokeIntegration(.{
            .causes = .{ .exact_revoke = true },
            .completed_present = true,
            .control = control,
        });
        try std.testing.expectEqual(TerminalReason.invariant_failure, revoked.terminal.?.reason);
        try std.testing.expect(revoked.suppress_tx);
    }

    const impossible_hup = planRevokeIntegration(.{
        .causes = .{ .peer_hup_drain_complete = true },
        .completed_present = true,
        .control = .none,
    });
    try std.testing.expectEqual(RevokeIntegrationAction.cleanup_completed, impossible_hup.action);
    try std.testing.expectEqual(TerminalReason.invariant_failure, impossible_hup.terminal.?.reason);
    try std.testing.expect(impossible_hup.suppress_tx);

    const completed_hup = planRevokeIntegration(.{
        .causes = .{ .peer_hup_hint = true },
        .completed_present = true,
        .control = .none,
    });
    try std.testing.expectEqual(
        RevokeIntegrationAction.continue_bounded_rx,
        completed_hup.action,
    );
    try std.testing.expect(completed_hup.suppress_tx);
    try std.testing.expect(completed_hup.bounded_rx_required);
}

test "f3a HUP cross product never weakens a sealed stronger cause" {
    const cases = [_]struct {
        causes: WholeTurnCauses,
        reason: TerminalReason,
    }{
        .{ .causes = .{ .deadline_expired = true }, .reason = .deadline_exceeded },
        .{ .causes = .{ .backwards_clock = true }, .reason = .invariant_failure },
        .{ .causes = .{ .invariant_or_corruption = true }, .reason = .invariant_failure },
        .{ .causes = .{ .resource_exhausted = true }, .reason = .resource_exhausted },
        .{ .causes = .{ .protocol_violation = true }, .reason = .protocol_error },
        .{ .causes = .{ .exact_revoke = true }, .reason = .revoked },
        .{ .causes = .{ .transport = .eof }, .reason = .eof },
        .{ .causes = .{ .transport = .socket_error }, .reason = .socket_error },
    };
    const controls = [_]F3ControlProgress{
        .none,
        .queued,
        .partial,
        .fully_sent,
        .response_wait,
        .missing,
        .invalid,
    };
    for (cases) |case| {
        for ([_]bool{ false, true }) |drained| {
            for ([_]bool{ false, true }) |completed| {
                for (controls) |control| {
                    var causes = case.causes;
                    causes.peer_hup_hint = true;
                    causes.peer_hup_drain_complete = drained;
                    const plan = planRevokeIntegration(.{
                        .causes = causes,
                        .completed_present = completed,
                        .control = control,
                    });
                    const canonical_reason: TerminalReason = if (completed and
                        control != .none and !causes.deadline_expired)
                        .invariant_failure
                    else if (!completed and case.reason == .revoked and
                        control != .none and control != .queued)
                        .protocol_error
                    else
                        case.reason;
                    try std.testing.expectEqual(canonical_reason, plan.terminal.?.reason);
                    try std.testing.expect(plan.suppress_tx);
                    try std.testing.expect(!plan.bounded_rx_required);
                }
            }
        }
    }
}

test "f3e pure hostile matrix seals response revoke HUP control progress and deadline precedence" {
    const controls = std.meta.tags(F3ControlProgress);
    for ([_]bool{ false, true }) |completed| {
        for ([_]bool{ false, true }) |revoked| {
            for ([_]bool{ false, true }) |hup| {
                for ([_]bool{ false, true }) |hup_drained| {
                    if (hup_drained and !hup) continue;
                    for (controls) |control| {
                        const plan = planRevokeIntegration(.{
                            .causes = .{
                                .exact_revoke = revoked,
                                .peer_hup_hint = hup,
                                .peer_hup_drain_complete = hup_drained,
                            },
                            .completed_present = completed,
                            .control = control,
                        });
                        if (completed and control != .none) {
                            try std.testing.expectEqual(
                                RevokeIntegrationAction.cleanup_completed,
                                plan.action,
                            );
                            try std.testing.expectEqual(
                                TerminalReason.invariant_failure,
                                plan.terminal.?.reason,
                            );
                            try std.testing.expect(plan.suppress_tx);
                            continue;
                        }
                        if (hup and !hup_drained and !revoked) {
                            try std.testing.expectEqual(
                                RevokeIntegrationAction.continue_bounded_rx,
                                plan.action,
                            );
                            try std.testing.expect(plan.bounded_rx_required);
                            try std.testing.expect(plan.suppress_tx);
                            continue;
                        }
                        if (completed) {
                            try std.testing.expectEqual(
                                if (revoked or hup_drained)
                                    RevokeIntegrationAction.cleanup_completed
                                else
                                    RevokeIntegrationAction.success_candidate,
                                plan.action,
                            );
                        } else if (revoked and
                            (control == .none or control == .queued))
                        {
                            try std.testing.expectEqual(
                                RevokeIntegrationAction.cancel_queued,
                                plan.action,
                            );
                        } else {
                            try std.testing.expectEqual(
                                RevokeIntegrationAction.poison_close,
                                plan.action,
                            );
                        }
                        if (revoked or hup_drained)
                            try std.testing.expect(plan.suppress_tx);
                    }
                }
            }
        }
    }

    const deadline: i128 = 1_000;
    for ([_]i128{ deadline - 1, deadline, deadline + 1 }) |now_ns| {
        const decision = decide(.{
            .turn = .{ .readable = true, .writable = true, .now_ns = now_ns },
            .parser = .empty,
            .socket_rx_drained = true,
            .tx_pending = true,
            .control_ready = true,
            .deadlines = .{ deadline, null, null, null, null },
        });
        if (now_ns < deadline) {
            try std.testing.expect(decision.terminal == null);
            try std.testing.expect(decision.write_interest);
            try std.testing.expect(decision.control_ready);
        } else {
            try std.testing.expectEqual(
                TerminalReason.deadline_exceeded,
                decision.terminal.?.reason,
            );
            try std.testing.expect(!decision.read_interest);
            try std.testing.expect(!decision.write_interest);
            try std.testing.expect(!decision.control_ready);
        }
    }
}

pub const RecoveryDisposition = enum {
    no_op,
    entered,
    promoted_to_host,
    acknowledged,
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
    /// Supplied only by the sealed resync ACK consumer. It is the absolute end of the completed
    /// response frame and therefore the first legal recovery-snapshot start.
    recovery_barrier_absolute: ?u64 = null,
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
        .valid => null,
        .host_recovery => |phase| switch (phase) {
            .ack_unadmitted => |context| context,
            .ack_queued => |context| context,
            .awaiting_snapshot => |waiting| waiting.context,
            .snapshot_in_flight => |in_flight| in_flight.context,
            .applied_pending => |waiting| waiting.context,
        },
        .client_recovery => |phase| switch (phase) {
            .control_wait => |context| context,
            .control_in_flight => |context| context,
            .awaiting_snapshot => |waiting| waiting.context,
            .snapshot_in_flight => |in_flight| in_flight.context,
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

fn planResyncAcknowledgement(input: RecoveryTransitionInput) RecoveryTransitionPlan {
    if (input.new_context != null or input.control != .response_wait) return terminalRecoveryPlan();
    const barrier = input.recovery_barrier_absolute orelse return terminalRecoveryPlan();
    if (barrier == 0) return terminalRecoveryPlan();
    const context = switch (input.state) {
        .client_recovery => |phase| switch (phase) {
            .control_in_flight => |value| value,
            else => return terminalRecoveryPlan(),
        },
        else => return terminalRecoveryPlan(),
    };
    if (context.epoch == 0 or input.now_ns >= context.deadline_ns)
        return terminalRecoveryPlan();
    return .{
        .disposition = .acknowledged,
        .next = .{ .client_recovery = .{ .awaiting_snapshot = .{
            .context = context,
            .recovery_barrier_absolute = barrier,
        } } },
    };
}

/// Closed allocation-free interpretation of the normative 2b2e collision table. It never mutates
/// queues or controls; the storage layer must seal the returned actions with its cleanup aggregate
/// and commit them in one no-callback suffix.
pub fn planRecoveryTransition(
    input: RecoveryTransitionInput,
) RecoveryTransitionPlan {
    if (input.trigger == .resync_ack) return planResyncAcknowledgement(input);
    if (input.recovery_barrier_absolute != null) return terminalRecoveryPlan();
    if (input.trigger == .fresh_commit) return planFreshRecoveryCommit(input);

    switch (input.state) {
        .valid => {
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
                .awaiting_snapshot, .snapshot_in_flight, .applied_pending => false,
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
        .recovery_barrier_absolute = 4,
    };
    const in_flight = SnapshotInFlight{
        .context = waiting.context,
        .recovery_barrier_absolute = waiting.recovery_barrier_absolute,
        .expected_token_generation = 9,
    };
    const host = AuthorityState{ .host_recovery = .{ .awaiting_snapshot = waiting } };
    const client = AuthorityState{ .client_recovery = .{ .applied_pending = in_flight } };
    try std.testing.expect(host == .host_recovery);
    try std.testing.expect(client == .client_recovery);
    try std.testing.expectEqual(@as(u64, 7), host.host_recovery.awaiting_snapshot.context.epoch);
    try std.testing.expectEqual(@as(u64, 7), client.client_recovery.applied_pending.context.epoch);
}

test "2b2e integration binds only exact post-barrier snapshot and committed ledger token" {
    const waiting = AwaitingSnapshot{
        .context = .{ .epoch = 7, .deadline_ns = 30 },
        .recovery_barrier_absolute = 41,
    };
    inline for (.{ RecoveryOrigin.host, RecoveryOrigin.client }) |origin| {
        const state: AuthorityState = switch (origin) {
            .host => .{ .host_recovery = .{ .awaiting_snapshot = waiting } },
            .client => .{ .client_recovery = .{ .awaiting_snapshot = waiting } },
        };
        const candidate = RecoverySnapshotCandidate{
            .origin = origin,
            .recovery_epoch = waiting.context.epoch,
            .is_snapshot = true,
            .start_absolute = waiting.recovery_barrier_absolute,
            .end_absolute = waiting.recovery_barrier_absolute + 1,
            .committed_token_generation = 9,
        };
        const plan = planRecoverySnapshotBinding(state, candidate);
        try std.testing.expectEqual(
            RecoverySnapshotBindingDisposition.bound,
            plan.disposition,
        );
        const bound = switch (plan.next) {
            .host_recovery => |phase| phase.snapshot_in_flight,
            .client_recovery => |phase| phase.snapshot_in_flight,
            .valid => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(u64, 7), bound.context.epoch);
        try std.testing.expectEqual(@as(u64, 41), bound.recovery_barrier_absolute);
        try std.testing.expectEqual(@as(u64, 9), bound.expected_token_generation);

        const hostile = [_]RecoverySnapshotCandidate{
            .{ .origin = origin, .recovery_epoch = 7, .is_snapshot = true, .start_absolute = 41, .end_absolute = 42, .committed_token_generation = 0 },
            .{ .origin = origin, .recovery_epoch = 7, .is_snapshot = false, .start_absolute = 41, .end_absolute = 42, .committed_token_generation = 9 },
            .{ .origin = origin, .recovery_epoch = 7, .is_snapshot = true, .start_absolute = 40, .end_absolute = 42, .committed_token_generation = 9 },
            .{ .origin = origin, .recovery_epoch = 7, .is_snapshot = true, .start_absolute = 41, .end_absolute = 41, .committed_token_generation = 9 },
            .{ .origin = origin, .recovery_epoch = 8, .is_snapshot = true, .start_absolute = 41, .end_absolute = 42, .committed_token_generation = 9 },
            .{ .origin = if (origin == .host) .client else .host, .recovery_epoch = 7, .is_snapshot = true, .start_absolute = 41, .end_absolute = 42, .committed_token_generation = 9 },
        };
        for (hostile) |invalid_candidate| {
            const rejected = planRecoverySnapshotBinding(state, invalid_candidate);
            try std.testing.expectEqual(
                RecoverySnapshotBindingDisposition.terminal,
                rejected.disposition,
            );
            try std.testing.expect(std.meta.eql(state, rejected.next));
        }
    }

    const wrong_phase: AuthorityState = .{ .client_recovery = .{
        .control_wait = waiting.context,
    } };
    const rejected = planRecoverySnapshotBinding(wrong_phase, .{
        .origin = .client,
        .recovery_epoch = 7,
        .is_snapshot = true,
        .start_absolute = 41,
        .end_absolute = 42,
        .committed_token_generation = 9,
    });
    try std.testing.expectEqual(
        RecoverySnapshotBindingDisposition.terminal,
        rejected.disposition,
    );
    try std.testing.expect(std.meta.eql(wrong_phase, rejected.next));
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

test "2b2e integration recovery reducer acknowledges only exact response wait before deadline" {
    const context = RecoveryContext{ .epoch = 13, .deadline_ns = 100 };
    const state: AuthorityState = .{ .client_recovery = .{ .control_in_flight = context } };
    const acknowledged = planRecoveryTransition(.{
        .state = state,
        .trigger = .resync_ack,
        .control = .response_wait,
        .now_ns = 99,
        .recovery_barrier_absolute = 41,
    });
    try std.testing.expectEqual(RecoveryDisposition.acknowledged, acknowledged.disposition);
    try std.testing.expect(acknowledged.next == .client_recovery);
    try std.testing.expect(std.meta.eql(
        AwaitingSnapshot{
            .context = context,
            .recovery_barrier_absolute = 41,
        },
        acknowledged.next.client_recovery.awaiting_snapshot,
    ));
    try std.testing.expect(!acknowledged.drop_backlog);
    try std.testing.expect(!acknowledged.cancel_control);

    const invalid = [_]RecoveryTransitionInput{
        .{
            .state = state,
            .trigger = .resync_ack,
            .control = .fully_sent,
            .now_ns = 99,
            .recovery_barrier_absolute = 41,
        },
        .{
            .state = state,
            .trigger = .resync_ack,
            .control = .response_wait,
            .now_ns = 99,
            .recovery_barrier_absolute = 0,
        },
        .{
            .state = state,
            .trigger = .resync_ack,
            .control = .response_wait,
            .now_ns = 100,
            .recovery_barrier_absolute = 41,
        },
        .{
            .state = .{ .client_recovery = .{ .awaiting_snapshot = .{
                .context = context,
                .recovery_barrier_absolute = 40,
            } } },
            .trigger = .resync_ack,
            .control = .response_wait,
            .now_ns = 99,
            .recovery_barrier_absolute = 41,
        },
        .{
            .state = .{ .host_recovery = .{ .ack_queued = context } },
            .trigger = .resync_ack,
            .control = .response_wait,
            .now_ns = 99,
            .recovery_barrier_absolute = 41,
        },
    };
    for (invalid) |input| {
        const rejected = planRecoveryTransition(input);
        try std.testing.expectEqual(RecoveryDisposition.terminal, rejected.disposition);
        try std.testing.expect(!rejected.drop_backlog);
        try std.testing.expect(!rejected.cancel_control);
    }
}

test "recovery reducer keeps duplicate origin epoch and deadline immutable" {
    const context = RecoveryContext{ .epoch = 8, .deadline_ns = 300 };
    const waiting = AwaitingSnapshot{
        .context = context,
        .recovery_barrier_absolute = 4,
    };
    const in_flight = SnapshotInFlight{
        .context = context,
        .recovery_barrier_absolute = 4,
        .expected_token_generation = 17,
    };
    const states = [_]AuthorityState{
        .{ .host_recovery = .{ .ack_unadmitted = context } },
        .{ .host_recovery = .{ .ack_queued = context } },
        .{ .host_recovery = .{ .awaiting_snapshot = waiting } },
        .{ .host_recovery = .{ .snapshot_in_flight = in_flight } },
        .{ .host_recovery = .{ .applied_pending = in_flight } },
        .{ .client_recovery = .{ .control_wait = context } },
        .{ .client_recovery = .{ .control_in_flight = context } },
        .{ .client_recovery = .{ .awaiting_snapshot = waiting } },
        .{ .client_recovery = .{ .snapshot_in_flight = in_flight } },
        .{ .client_recovery = .{ .applied_pending = in_flight } },
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
        .recovery_barrier_absolute = 4,
    };
    const in_flight = SnapshotInFlight{
        .context = context,
        .recovery_barrier_absolute = 4,
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
            .state = .{ .client_recovery = .{ .snapshot_in_flight = in_flight } },
            .progress = .none,
        },
        .{
            .state = .{ .client_recovery = .{ .applied_pending = in_flight } },
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
    const in_flight = SnapshotInFlight{
        .context = .{ .epoch = 5, .deadline_ns = 100 },
        .recovery_barrier_absolute = 4,
        .expected_token_generation = 19,
    };
    for ([_]AuthorityState{
        .{ .host_recovery = .{ .applied_pending = in_flight } },
        .{ .client_recovery = .{ .applied_pending = in_flight } },
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
        .state = .{ .host_recovery = .{ .snapshot_in_flight = in_flight } },
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

test "S11-6 observer 가 보낼 수 있는 control 은 detach 와 declare_viewport 둘뿐이다" {
    const T = std.testing;
    // **이 표가 곧 정책이다.** 폰은 언제나 observer 라, 선언에 controller 자격을 요구하면 기능이
    // 통째로 죽는다 — 그런데 그 실패는 「선언이 그냥 안 먹는다」로만 보여서 눈에 안 띈다.
    try T.expect(ControlKind.resize.requiresController());
    try T.expect(ControlKind.resync.requiresController());
    try T.expect(!ControlKind.detach.requiresController());
    try T.expect(!ControlKind.declare_viewport.requiresController());
}
