//! External session-host pump policy and closed state DTOs.
//!
//! This module deliberately knows nothing about file descriptors, MRSH framing, JSON, allocators,
//! or the inbox ledger. Keeping the turn decision pure lets socket adapters and deterministic tests
//! share one deadline/priority policy without creating a second transport implementation.

const std = @import("std");

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
    rx_frames: usize = 0,
    tx_bytes: usize = 0,
    tx_frames: usize = 0,
    read_interest: bool = false,
    write_interest: bool = false,
    immediate_rx: bool = false,
    authority_clear: bool = false,
    control_ready: bool = false,
    terminal: ?ExternalPumpTerminal = null,
    next_deadline_ns: ?i128 = null,
};

pub const RequestIdState = @import("request_id_state.zig").State;

pub const RecoveryOrigin = enum {
    host,
    client,
};

pub const RecoveryKey = struct {
    origin: RecoveryOrigin,
    recovery_epoch: u64,
    expected_token_generation: u64,
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

pub const ParserReadiness = enum {
    empty,
    incomplete,
    complete_or_error,
};

pub const PolicyInput = struct {
    turn: TurnInput,
    parser: ParserReadiness,
    socket_rx_drained: bool,
    rx_budget_exhausted: bool = false,
    tx_pending: bool = false,
    control_ready: bool = false,
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

    result.immediate_rx = input.rx_budget_exhausted or input.parser == .complete_or_error;
    result.authority_clear = input.socket_rx_drained and
        input.parser == .empty and
        !input.rx_budget_exhausted;
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
    try std.testing.expect(!partial.control_ready);
    try std.testing.expect(!partial.write_interest);

    const backlog = decide(.{
        .turn = .{ .readable = false, .writable = true, .now_ns = 1 },
        .parser = .complete_or_error,
        .socket_rx_drained = true,
    });
    try std.testing.expect(!backlog.authority_clear);
    try std.testing.expect(backlog.immediate_rx);

    const budget = decide(.{
        .turn = .{ .readable = true, .writable = true, .now_ns = 1 },
        .parser = .empty,
        .socket_rx_drained = true,
        .rx_budget_exhausted = true,
        .tx_pending = true,
    });
    try std.testing.expect(budget.immediate_rx);
    try std.testing.expect(!budget.authority_clear);
    try std.testing.expect(!budget.write_interest);
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
