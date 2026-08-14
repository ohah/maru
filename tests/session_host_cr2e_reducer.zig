//! CR2e-a의 reconnect 상태 전이는 이 테스트가 소비하는 pointer-free reducer 하나만 소유한다.
//! 실제 generation 저장소와 transport executor는 후속 CR2e-c/d가 같은 Decision을 소비한다.

const std = @import("std");
const reducer = @import("reconnect_reducer");

const work: reducer.Work = .{
    .job_generation = 3,
    .shell_generation = 7,
    .attempt = 1,
    .candidate_connection_generation = 2,
    .deadline_ns = 100,
};
const close_intent: reducer.CloseIntent = .{
    .intent_generation = 1,
    .shell_generation = 7,
    .deadline_ns = 300,
};
fn retryReservation(shell_generation: u64) reducer.RetryReservation {
    return .{ .row_id = 7, .generation = 11, .shell_generation = shell_generation };
}

test "CR2e-a reducer는 clean precommit 실패만 old writable로 복귀시킨다" {
    var state = reducer.State.initial(3, 7);
    state = (try reducer.reduce(state, .{ .begin_prepare = work })).state;
    state = (try reducer.reduce(state, .observer_staged)).state;
    state = (try reducer.reduce(state, .begin_mutation_seal)).state;
    state = (try reducer.reduce(state, .seal_clean)).state;

    const result = try reducer.reduce(state, .precommit_failed_clean);
    try std.testing.expectEqual(reducer.Decision.abort_candidate_restore_old, result.decision);
    try std.testing.expectEqual(reducer.JobPhase.healthy, result.state.phaseTag());
    try std.testing.expectEqual(reducer.LocalState.published_old, result.state.local);
    try std.testing.expectEqual(reducer.MutationState.open, result.state.mutation);

    var ambiguous = reducer.State.initial(3, 7);
    ambiguous = (try reducer.reduce(ambiguous, .{ .begin_prepare = work })).state;
    ambiguous = (try reducer.reduce(ambiguous, .observer_staged)).state;
    ambiguous = (try reducer.reduce(ambiguous, .begin_mutation_seal)).state;
    ambiguous = (try reducer.reduce(ambiguous, .seal_ambiguous)).state;
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(ambiguous, .{
        .precommit_failed_ambiguous_unusable = .{
            .row_id = 0,
            .generation = 11,
            .shell_generation = 7,
        },
    }));
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(ambiguous, .{
        .precommit_failed_ambiguous_unusable = retryReservation(8),
    }));
    const frozen = try reducer.reduce(ambiguous, .{
        .precommit_failed_ambiguous_unusable = retryReservation(7),
    });
    try std.testing.expectEqual(reducer.Decision.abort_candidate_freeze_old, frozen.decision);
    try std.testing.expectEqual(reducer.LocalState.frozen_unavailable, frozen.state.local);
    try std.testing.expectEqual(reducer.MutationState.closed, frozen.state.mutation);
}

test "CR2e-a reducer는 evidence 없는 publish와 writable reopen을 거부한다" {
    var state = reducer.State.initial(3, 7);
    state = (try reducer.reduce(state, .{ .begin_prepare = work })).state;
    state = (try reducer.reduce(state, .observer_staged)).state;
    state = (try reducer.reduce(state, .begin_mutation_seal)).state;
    state = (try reducer.reduce(state, .seal_clean)).state;
    state = (try reducer.reduce(state, .begin_authority_commit)).state;

    try std.testing.expectError(error.IllegalTransition, reducer.reduce(state, .publish_new));
    state = (try reducer.reduce(state, .controller_evidenced)).state;
    state = (try reducer.reduce(state, .begin_publish)).state;
    const published = try reducer.reduce(state, .publish_new);
    try std.testing.expectEqual(reducer.Decision.publish_new_and_open, published.decision);
    try std.testing.expectEqual(reducer.JobPhase.publishing, published.state.phaseTag());
    try std.testing.expectEqual(reducer.LocalState.published_new, published.state.local);
    try std.testing.expectEqual(reducer.MutationState.open, published.state.mutation);
    try std.testing.expectEqual(@as(u64, 8), published.state.shell_generation);
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(published.state, .publish_new));
    const completed = try reducer.completeJob(published.state, .{
        .job_generation = 3,
        .total = 1,
        .published_new = 1,
        .frozen_unavailable = 0,
        .ended = 0,
        .retry_reserved = 0,
    });
    try std.testing.expectEqual(reducer.JobPhase.healthy, completed.state.phaseTag());
}

test "CR2e-a reducer는 close 경쟁과 mixed frozen retry를 닫힌 상태로 보존한다" {
    var state = reducer.State.initial(3, 7);
    state = (try reducer.reduce(state, .{ .begin_prepare = work })).state;
    const pending = try reducer.reduce(state, .{ .close_requested = close_intent });
    try std.testing.expectEqual(reducer.Decision.publish_termination_pending, pending.decision);
    try std.testing.expectEqual(reducer.CloseTag.termination_pending, std.meta.activeTag(pending.state.close));
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(pending.state, .publish_new));
    try std.testing.expectError(
        error.IllegalTransition,
        reducer.reduce(pending.state, .{ .close_timed_out = .{ .now_ns = 299 } }),
    );
    const unconfirmed = try reducer.reduce(pending.state, .{ .close_timed_out = .{ .now_ns = 300 } });
    try std.testing.expectEqual(
        reducer.CloseTag.termination_unconfirmed,
        std.meta.activeTag(unconfirmed.state.close),
    );
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(unconfirmed.state, .{
        .reconnect_quiesced_for_close = .{
            .old_transport_usable = true,
            .retry = retryReservation(7),
        },
    }));
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(unconfirmed.state, .{
        .reconnect_quiesced_for_close = .{ .old_transport_usable = false, .retry = null },
    }));
    const quiesced = try reducer.reduce(unconfirmed.state, .{
        .reconnect_quiesced_for_close = .{ .old_transport_usable = true, .retry = null },
    });
    try std.testing.expectEqual(reducer.Decision.close_preserve_old, quiesced.decision);
    try std.testing.expectEqual(reducer.JobPhase.healthy, quiesced.state.phaseTag());
    const abandoned = try reducer.reduce(quiesced.state, .abandon_to_inventory);
    try std.testing.expectEqual(reducer.LocalState.ended, abandoned.state.local);

    var mixed = reducer.State.initial(3, 7);
    mixed = (try reducer.reduce(mixed, .{ .begin_prepare = work })).state;
    mixed = (try reducer.reduce(mixed, .observer_staged)).state;
    mixed = (try reducer.reduce(mixed, .begin_mutation_seal)).state;
    mixed = (try reducer.reduce(mixed, .seal_clean)).state;
    mixed = (try reducer.reduce(mixed, .begin_authority_commit)).state;
    mixed = (try reducer.reduce(mixed, .takeover_sent_unknown)).state;
    mixed = (try reducer.reduce(mixed, .begin_publish)).state;
    const frozen = try reducer.reduce(mixed, .{
        .freeze_with_reserved_retry = retryReservation(7),
    });
    try std.testing.expectEqual(reducer.Decision.publish_unavailable_with_retry, frozen.decision);
    try std.testing.expectEqual(retryReservation(7), frozen.state.retry.?);
    try std.testing.expectEqual(reducer.LocalState.frozen_unavailable, frozen.state.local);
    try std.testing.expectEqual(reducer.MutationState.closed, frozen.state.mutation);
    try std.testing.expectError(
        error.IllegalTransition,
        reducer.reduce(frozen.state, .{ .freeze_with_reserved_retry = retryReservation(7) }),
    );
    try std.testing.expectError(error.IllegalTransition, reducer.completeJob(frozen.state, .{
        .job_generation = 3,
        .total = 2,
        .published_new = 1,
        .frozen_unavailable = 1,
        .ended = 0,
        .retry_reserved = 0,
    }));
    const completed = try reducer.completeJob(frozen.state, .{
        .job_generation = 3,
        .total = 2,
        .published_new = 1,
        .frozen_unavailable = 1,
        .ended = 0,
        .retry_reserved = 1,
    });
    try std.testing.expectEqual(reducer.JobPhase.healthy, completed.state.phaseTag());
    try std.testing.expectEqual(reducer.MutationState.closed, completed.state.mutation);
}

test "CR2e-a reducer는 closed inventory와 forged summary를 전수 거부한다" {
    try std.testing.expect(!containsPointer(reducer.State));
    try std.testing.expect(!containsPointer(reducer.Event));
    try std.testing.expect(!containsPointer(reducer.Decision));
    try std.testing.expect(!containsPointer(reducer.TerminalSummary));
    try std.testing.expectEqual(@as(usize, 7), @typeInfo(reducer.JobPhase).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 6), @typeInfo(reducer.RuntimeLedger).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(reducer.LocalState).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(reducer.MutationState).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(reducer.CloseTag).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 4), @typeInfo(reducer.CloseState).@"union".fields.len);
    try std.testing.expectEqual(@as(usize, 26), @typeInfo(reducer.EventTag).@"enum".fields.len);
    try std.testing.expectEqual(@as(usize, 26), @typeInfo(reducer.Event).@"union".fields.len);
    try std.testing.expectEqual(@as(usize, 31), @typeInfo(reducer.Decision).@"enum".fields.len);

    var wrong_shell_work = work;
    wrong_shell_work.shell_generation = 8;
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(
        reducer.State.initial(3, 7),
        .{ .begin_prepare = wrong_shell_work },
    ));
    var wrong_shell_close = close_intent;
    wrong_shell_close.shell_generation = 8;
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(
        reducer.State.initial(3, 7),
        .{ .close_requested = wrong_shell_close },
    ));

    var legal_initial_events: usize = 0;
    const events = [_]reducer.Event{
        .{ .begin_prepare = work },                                                                                                                                                       .observer_staged,                                                             .begin_mutation_seal,                                   .seal_clean,
        .seal_ambiguous,                                                                                                                                                                  .precommit_failed_clean,                                                      .precommit_failed_ambiguous_usable,                     .{ .precommit_failed_ambiguous_unusable = retryReservation(7) },
        .begin_authority_commit,                                                                                                                                                          .takeover_sent_unknown,                                                       .controller_evidenced,                                  .authority_conflict,
        .gone_positive,                                                                                                                                                                   .{ .begin_retry_wait_release = .{ .work = work, .runtime_id = .{1} ** 16 } }, .retry_direct_granted,                                  .{ .retry_expired = .{ .now_ns = 100 } },
        .begin_publish,                                                                                                                                                                   .publish_new,                                                                 .{ .freeze_with_reserved_retry = retryReservation(7) }, .end_runtime,
        .{ .prepare_unavailable = .{ .job_generation = 3, .shell_generation = 7, .last_attempt = 1, .last_candidate_connection_generation = 2, .retry_at_ns = 50, .deadline_ns = 100 } }, .{ .retry_unavailable = .{ .work = work, .clock = .{ .now_ns = 50 } } },      .{ .close_requested = close_intent },                   .{ .reconnect_quiesced_for_close = .{ .old_transport_usable = true, .retry = null } },
        .{ .close_timed_out = .{ .now_ns = 300 } },                                                                                                                                       .abandon_to_inventory,
    };
    for (events) |event| {
        if (reducer.reduce(reducer.State.initial(3, 7), event)) |_| {
            legal_initial_events += 1;
        } else |err| try std.testing.expectEqual(error.IllegalTransition, err);
    }
    try std.testing.expectEqual(@as(usize, 2), legal_initial_events);

    var forged = reducer.State.initial(3, 7);
    forged.retry = retryReservation(7);
    try std.testing.expect(!reducer.valid(forged));
    forged.local = .frozen_unavailable;
    forged.mutation = .closed;
    forged.retry = .{ .row_id = 7, .generation = 0, .shell_generation = 7 };
    try std.testing.expect(!reducer.valid(forged));
    forged = reducer.State.initial(3, 7);
    forged.shell_generation = 0;
    try std.testing.expect(!reducer.valid(forged));
    forged = reducer.State.initial(3, 7);
    forged.ledger = .new_controller_evidenced;
    try std.testing.expect(!reducer.valid(forged));

    var publishing = reducer.State.initial(3, 7);
    publishing = (try reducer.reduce(publishing, .{ .begin_prepare = work })).state;
    publishing = (try reducer.reduce(publishing, .observer_staged)).state;
    publishing = (try reducer.reduce(publishing, .begin_mutation_seal)).state;
    publishing = (try reducer.reduce(publishing, .seal_clean)).state;
    publishing = (try reducer.reduce(publishing, .begin_authority_commit)).state;
    publishing = (try reducer.reduce(publishing, .controller_evidenced)).state;
    publishing = (try reducer.reduce(publishing, .begin_publish)).state;
    publishing = (try reducer.reduce(publishing, .publish_new)).state;
    try std.testing.expectError(error.IllegalTransition, reducer.completeJob(publishing, .{
        .job_generation = 2,
        .total = 1,
        .published_new = 1,
        .frozen_unavailable = 0,
        .ended = 0,
        .retry_reserved = 0,
    }));
    try std.testing.expectError(error.IllegalTransition, reducer.completeJob(publishing, .{
        .job_generation = 3,
        .total = 1,
        .published_new = 0,
        .frozen_unavailable = 1,
        .ended = 0,
        .retry_reserved = 1,
    }));

    var waiting = reducer.State.initial(3, 7);
    waiting = (try reducer.reduce(waiting, .{ .begin_prepare = work })).state;
    waiting = (try reducer.reduce(waiting, .observer_staged)).state;
    waiting = (try reducer.reduce(waiting, .begin_mutation_seal)).state;
    waiting = (try reducer.reduce(waiting, .seal_clean)).state;
    waiting = (try reducer.reduce(waiting, .begin_authority_commit)).state;
    waiting = (try reducer.reduce(waiting, .authority_conflict)).state;
    waiting = (try reducer.reduce(waiting, .{ .begin_retry_wait_release = .{
        .work = work,
        .runtime_id = .{1} ** 16,
    } })).state;
    try std.testing.expectEqual(reducer.JobPhase.retry_wait_release, waiting.phaseTag());
    try std.testing.expectError(
        error.IllegalTransition,
        reducer.reduce(waiting, .{ .retry_expired = .{ .now_ns = 99 } }),
    );
    waiting = (try reducer.reduce(waiting, .{ .retry_expired = .{ .now_ns = 100 } })).state;
    try std.testing.expectEqual(reducer.JobPhase.publishing, waiting.phaseTag());

    var unavailable = reducer.State.initial(3, 7);
    unavailable = (try reducer.reduce(unavailable, .{ .begin_prepare = work })).state;
    unavailable = (try reducer.reduce(unavailable, .{ .prepare_unavailable = .{
        .job_generation = 3,
        .shell_generation = 7,
        .last_attempt = 1,
        .last_candidate_connection_generation = 2,
        .retry_at_ns = 50,
        .deadline_ns = 100,
    } })).state;
    try std.testing.expectEqual(reducer.JobPhase.unavailable, unavailable.phaseTag());
    try std.testing.expectError(error.IllegalTransition, reducer.reduce(unavailable, .{
        .retry_unavailable = .{
            .work = .{
                .job_generation = 3,
                .shell_generation = 7,
                .attempt = 2,
                .candidate_connection_generation = 3,
                .deadline_ns = 200,
            },
            .clock = .{ .now_ns = 49 },
        },
    }));
    unavailable = (try reducer.reduce(unavailable, .{ .retry_unavailable = .{
        .work = .{
            .job_generation = 3,
            .shell_generation = 7,
            .attempt = 2,
            .candidate_connection_generation = 3,
            .deadline_ns = 200,
        },
        .clock = .{ .now_ns = 50 },
    } })).state;
    try std.testing.expectEqual(reducer.JobPhase.preparing, unavailable.phaseTag());
}

test "CR2e-a reducer는 canonical authority prefix의 legal event 집합을 exact 고정한다" {
    const initial = reducer.State.initial(3, 7);
    try expectAllowed(initial, &.{ .begin_prepare, .close_requested });

    const preparing = (try reducer.reduce(initial, .{ .begin_prepare = work })).state;
    try expectAllowed(preparing, &.{ .observer_staged, .prepare_unavailable, .close_requested });
    const staged = (try reducer.reduce(preparing, .observer_staged)).state;
    try expectAllowed(staged, &.{ .begin_mutation_seal, .close_requested });
    const sealing = (try reducer.reduce(staged, .begin_mutation_seal)).state;
    try expectAllowed(sealing, &.{ .seal_clean, .seal_ambiguous, .close_requested });
    const clean = (try reducer.reduce(sealing, .seal_clean)).state;
    try expectAllowed(clean, &.{ .precommit_failed_clean, .begin_authority_commit, .close_requested });
    const committing = (try reducer.reduce(clean, .begin_authority_commit)).state;
    try expectAllowed(committing, &.{
        .takeover_sent_unknown,
        .controller_evidenced,
        .authority_conflict,
        .gone_positive,
        .close_requested,
    });
    const unknown = (try reducer.reduce(committing, .takeover_sent_unknown)).state;
    try expectAllowed(unknown, &.{
        .controller_evidenced,
        .authority_conflict,
        .gone_positive,
        .begin_publish,
        .close_requested,
    });
    const conflict = (try reducer.reduce(unknown, .authority_conflict)).state;
    try expectAllowed(conflict, &.{
        .begin_retry_wait_release,
        .begin_publish,
        .close_requested,
    });
    const waiting = (try reducer.reduce(conflict, canonicalEvent(.begin_retry_wait_release))).state;
    try expectAllowed(waiting, &.{ .retry_direct_granted, .retry_expired, .close_requested });
}

fn expectAllowed(state: reducer.State, allowed: []const reducer.EventTag) !void {
    inline for (@typeInfo(reducer.EventTag).@"enum".fields) |field| {
        const tag: reducer.EventTag = @enumFromInt(field.value);
        const expected = for (allowed) |item| {
            if (item == tag) break true;
        } else false;
        if (reducer.reduce(state, canonicalEvent(tag))) |_| {
            try std.testing.expect(expected);
        } else |err| {
            try std.testing.expectEqual(error.IllegalTransition, err);
            try std.testing.expect(!expected);
        }
    }
}

fn canonicalEvent(tag: reducer.EventTag) reducer.Event {
    return switch (tag) {
        .begin_prepare => .{ .begin_prepare = work },
        .observer_staged => .observer_staged,
        .begin_mutation_seal => .begin_mutation_seal,
        .seal_clean => .seal_clean,
        .seal_ambiguous => .seal_ambiguous,
        .precommit_failed_clean => .precommit_failed_clean,
        .precommit_failed_ambiguous_usable => .precommit_failed_ambiguous_usable,
        .precommit_failed_ambiguous_unusable => .{
            .precommit_failed_ambiguous_unusable = retryReservation(7),
        },
        .begin_authority_commit => .begin_authority_commit,
        .takeover_sent_unknown => .takeover_sent_unknown,
        .controller_evidenced => .controller_evidenced,
        .authority_conflict => .authority_conflict,
        .gone_positive => .gone_positive,
        .begin_retry_wait_release => .{ .begin_retry_wait_release = .{
            .work = work,
            .runtime_id = .{1} ** 16,
        } },
        .retry_direct_granted => .retry_direct_granted,
        .retry_expired => .{ .retry_expired = .{ .now_ns = 100 } },
        .begin_publish => .begin_publish,
        .publish_new => .publish_new,
        .freeze_with_reserved_retry => .{
            .freeze_with_reserved_retry = retryReservation(7),
        },
        .end_runtime => .end_runtime,
        .prepare_unavailable => .{ .prepare_unavailable = .{
            .job_generation = 3,
            .shell_generation = 7,
            .last_attempt = 1,
            .last_candidate_connection_generation = 2,
            .retry_at_ns = 50,
            .deadline_ns = 100,
        } },
        .retry_unavailable => .{ .retry_unavailable = .{
            .work = .{
                .job_generation = 3,
                .shell_generation = 7,
                .attempt = 2,
                .candidate_connection_generation = 3,
                .deadline_ns = 200,
            },
            .clock = .{ .now_ns = 50 },
        } },
        .close_requested => .{ .close_requested = close_intent },
        .reconnect_quiesced_for_close => .{
            .reconnect_quiesced_for_close = .{ .old_transport_usable = true, .retry = null },
        },
        .close_timed_out => .{ .close_timed_out = .{ .now_ns = 300 } },
        .abandon_to_inventory => .abandon_to_inventory,
    };
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .error_union => |info| containsPointer(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}
