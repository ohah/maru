//! Session-host client poison taxonomy.
//!
//! A failure reason has one closed operational decision. Callers choose a reason, but cannot
//! separately claim that the same reason is expected, retryable, or connection-fatal. Keeping the
//! mapping here prevents reconnect policy from drifting across RemoteRuntime call sites.

const std = @import("std");

pub const Scope = enum { stream, connection, host };
pub const Disposition = enum { retry_status, reconnect, no_retry, gone };

pub const Outcome = enum {
    stream_generation_rejected,
    controller_busy,
    authorization_denied,
    runtime_absent_positive,
    connection_eof,
    read_timeout,
    transport_read_failure,
    planned_upgrade_reconnect,
    capability_incompatible,
    outbound_partial_write,
    outbound_write_ambiguous,
    event_queue_overflow,
    local_queue_exhausted,
    local_resource_exhausted,
    frame_malformed,
    response_correlation_lost,
    peer_contract_violation,
    local_invariant_violation,
    external_transfer_quarantined,
    attachment_cleanup_failed,
};

/// The only outcomes that may cross `Client.poison`. Semantic stream/host outcomes are absent on
/// purpose, so a caller cannot accidentally turn a retry/status decision into shared-connection
/// invalidation.
pub const ConnectionReason = enum {
    connection_eof,
    read_timeout,
    transport_read_failure,
    planned_upgrade_reconnect,
    capability_incompatible,
    outbound_partial_write,
    outbound_write_ambiguous,
    event_queue_overflow,
    local_queue_exhausted,
    local_resource_exhausted,
    frame_malformed,
    response_correlation_lost,
    peer_contract_violation,
    local_invariant_violation,
    external_transfer_quarantined,
    attachment_cleanup_failed,
};

pub const Decision = struct {
    scope: Scope,
    disposition: Disposition,
    transport_usable: bool,
    expected: bool,
};

pub fn decisionFor(outcome: Outcome) Decision {
    return switch (outcome) {
        .stream_generation_rejected => .{
            .scope = .stream,
            .disposition = .retry_status,
            .transport_usable = true,
            .expected = true,
        },
        .controller_busy, .authorization_denied => .{
            .scope = .stream,
            .disposition = .no_retry,
            .transport_usable = true,
            .expected = true,
        },
        .runtime_absent_positive => .{
            .scope = .host,
            .disposition = .gone,
            .transport_usable = true,
            .expected = true,
        },
        .capability_incompatible => .{
            .scope = .connection,
            .disposition = .no_retry,
            .transport_usable = false,
            .expected = true,
        },
        .connection_eof,
        .read_timeout,
        .transport_read_failure,
        .planned_upgrade_reconnect,
        .outbound_partial_write,
        .outbound_write_ambiguous,
        .local_resource_exhausted,
        => .{
            .scope = .connection,
            .disposition = .reconnect,
            .transport_usable = false,
            .expected = true,
        },
        .frame_malformed,
        .event_queue_overflow,
        .local_queue_exhausted,
        .response_correlation_lost,
        .peer_contract_violation,
        .local_invariant_violation,
        .external_transfer_quarantined,
        .attachment_cleanup_failed,
        => .{
            .scope = .connection,
            .disposition = .reconnect,
            .transport_usable = false,
            .expected = false,
        },
    };
}

pub fn outcomeForConnection(reason: ConnectionReason) Outcome {
    return switch (reason) {
        inline else => |tag| @field(Outcome, @tagName(tag)),
    };
}

pub fn decisionForConnection(reason: ConnectionReason) Decision {
    return decisionFor(outcomeForConnection(reason));
}

test "client poison taxonomy classifies every reason without caller supplied policy" {
    const Case = struct { outcome: Outcome, decision: Decision };
    const stream_retry: Decision = .{ .scope = .stream, .disposition = .retry_status, .transport_usable = true, .expected = true };
    const stream_no_retry: Decision = .{ .scope = .stream, .disposition = .no_retry, .transport_usable = true, .expected = true };
    const host_gone: Decision = .{ .scope = .host, .disposition = .gone, .transport_usable = true, .expected = true };
    const reconnect_expected: Decision = .{ .scope = .connection, .disposition = .reconnect, .transport_usable = false, .expected = true };
    const reconnect_unexpected: Decision = .{ .scope = .connection, .disposition = .reconnect, .transport_usable = false, .expected = false };
    const connection_no_retry: Decision = .{ .scope = .connection, .disposition = .no_retry, .transport_usable = false, .expected = true };
    const cases = [_]Case{
        .{ .outcome = .stream_generation_rejected, .decision = stream_retry },
        .{ .outcome = .controller_busy, .decision = stream_no_retry },
        .{ .outcome = .authorization_denied, .decision = stream_no_retry },
        .{ .outcome = .runtime_absent_positive, .decision = host_gone },
        .{ .outcome = .connection_eof, .decision = reconnect_expected },
        .{ .outcome = .read_timeout, .decision = reconnect_expected },
        .{ .outcome = .transport_read_failure, .decision = reconnect_expected },
        .{ .outcome = .planned_upgrade_reconnect, .decision = reconnect_expected },
        .{ .outcome = .capability_incompatible, .decision = connection_no_retry },
        .{ .outcome = .outbound_partial_write, .decision = reconnect_expected },
        .{ .outcome = .outbound_write_ambiguous, .decision = reconnect_expected },
        .{ .outcome = .event_queue_overflow, .decision = reconnect_unexpected },
        .{ .outcome = .local_queue_exhausted, .decision = reconnect_unexpected },
        .{ .outcome = .local_resource_exhausted, .decision = reconnect_expected },
        .{ .outcome = .frame_malformed, .decision = reconnect_unexpected },
        .{ .outcome = .response_correlation_lost, .decision = reconnect_unexpected },
        .{ .outcome = .peer_contract_violation, .decision = reconnect_unexpected },
        .{ .outcome = .local_invariant_violation, .decision = reconnect_unexpected },
        .{ .outcome = .external_transfer_quarantined, .decision = reconnect_unexpected },
        .{ .outcome = .attachment_cleanup_failed, .decision = reconnect_unexpected },
    };
    const outcomes = std.meta.tags(Outcome);
    try std.testing.expectEqual(outcomes.len, cases.len);
    inline for (outcomes, cases) |outcome, case| {
        try std.testing.expectEqual(outcome, case.outcome);
        try std.testing.expectEqual(case.decision, decisionFor(outcome));
    }
}

test "connection poison reason is an exhaustive connection-fatal subset" {
    inline for (std.meta.tags(ConnectionReason)) |reason| {
        const decision = decisionForConnection(reason);
        try std.testing.expectEqual(Scope.connection, decision.scope);
        try std.testing.expect(!decision.transport_usable);
        try std.testing.expectEqual(
            if (reason == .capability_incompatible) Disposition.no_retry else .reconnect,
            decision.disposition,
        );
    }
}

test "client poison taxonomy separates semantic outcomes from connection poison" {
    try std.testing.expectEqual(Decision{
        .scope = .stream,
        .disposition = .retry_status,
        .transport_usable = true,
        .expected = true,
    }, decisionFor(.stream_generation_rejected));
    try std.testing.expectEqual(Decision{
        .scope = .connection,
        .disposition = .reconnect,
        .transport_usable = false,
        .expected = false,
    }, decisionFor(.frame_malformed));
    try std.testing.expectEqual(Decision{
        .scope = .host,
        .disposition = .gone,
        .transport_usable = true,
        .expected = true,
    }, decisionFor(.runtime_absent_positive));
}
