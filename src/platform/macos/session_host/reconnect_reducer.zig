//! Reconnect job의 pointer-free 상태 전이 단일 출처.
//!
//! 이 모듈은 권위 객체나 allocator를 소유하지 않는다. 제품 executor는 `Decision`만 소비하며,
//! event payload는 후속 CR2e-d가 봉인한 evidence를 검증한 뒤에만 이 reducer에 전달한다.

const std = @import("std");

pub const JobPhase = enum(u8) {
    healthy,
    preparing,
    mutation_sealing,
    authority_committing,
    retry_wait_release,
    publishing,
    unavailable,
};

pub const Work = struct {
    job_generation: u64,
    shell_generation: u64,
    attempt: u64,
    candidate_connection_generation: u64,
    deadline_ns: u64,

    fn valid(self: Work) bool {
        return self.job_generation != 0 and self.shell_generation != 0 and self.attempt != 0 and
            self.candidate_connection_generation != 0 and self.deadline_ns != 0;
    }
};

pub const RetryWait = struct {
    work: Work,
    runtime_id: [16]u8,

    fn valid(self: RetryWait) bool {
        return self.work.valid() and !allZero(&self.runtime_id);
    }
};

pub const Unavailable = struct {
    job_generation: u64,
    shell_generation: u64,
    last_attempt: u64,
    last_candidate_connection_generation: u64,
    retry_at_ns: u64,
    deadline_ns: u64,

    fn valid(self: Unavailable) bool {
        return self.job_generation != 0 and self.shell_generation != 0 and self.last_attempt != 0 and
            self.last_candidate_connection_generation != 0 and self.retry_at_ns != 0 and
            self.deadline_ns >= self.retry_at_ns;
    }
};

pub const PhaseState = union(JobPhase) {
    healthy: u64,
    preparing: Work,
    mutation_sealing: Work,
    authority_committing: Work,
    retry_wait_release: RetryWait,
    publishing: Work,
    unavailable: Unavailable,
};

pub const RuntimeLedger = enum(u8) {
    old_valid,
    staged_observer,
    takeover_sent_unknown,
    new_controller_evidenced,
    authority_conflict,
    gone_positive,
};

pub const LocalState = enum(u8) {
    published_old,
    published_new,
    frozen_unavailable,
    ended,
};

pub const MutationState = enum(u8) {
    open,
    sealing,
    sealed_clean,
    sealed_ambiguous,
    closed,
};

pub const CloseTag = enum(u8) {
    none,
    termination_pending,
    termination_unconfirmed,
    abandoned_to_inventory,
};

pub const CloseIntent = struct {
    intent_generation: u64,
    shell_generation: u64,
    deadline_ns: u64,

    fn valid(self: CloseIntent) bool {
        return self.intent_generation != 0 and self.shell_generation != 0 and self.deadline_ns != 0;
    }
};

pub const CloseState = union(CloseTag) {
    none: void,
    termination_pending: CloseIntent,
    termination_unconfirmed: CloseIntent,
    abandoned_to_inventory: u64,
};

pub const ClockEvidence = struct { now_ns: u64 };
pub const UnavailableRetry = struct { work: Work, clock: ClockEvidence };
pub const RetryReservation = struct {
    row_id: u64,
    generation: u64,
    shell_generation: u64,

    fn valid(self: RetryReservation) bool {
        return self.row_id != 0 and self.generation != 0 and self.shell_generation != 0;
    }
};
pub const CloseQuiescence = struct {
    old_transport_usable: bool,
    retry: ?RetryReservation,
};

pub const State = struct {
    phase: PhaseState,
    ledger: RuntimeLedger,
    local: LocalState,
    mutation: MutationState,
    close: CloseState,
    shell_generation: u64,
    retry: ?RetryReservation,

    pub fn initial(job_generation: u64, shell_generation: u64) State {
        std.debug.assert(job_generation != 0 and shell_generation != 0);
        return .{
            .phase = .{ .healthy = job_generation },
            .ledger = .old_valid,
            .local = .published_old,
            .mutation = .open,
            .close = .{ .none = {} },
            .shell_generation = shell_generation,
            .retry = null,
        };
    }

    pub fn phaseTag(self: State) JobPhase {
        return std.meta.activeTag(self.phase);
    }
};

pub const EventTag = enum(u8) {
    begin_prepare,
    observer_staged,
    begin_mutation_seal,
    seal_clean,
    seal_ambiguous,
    precommit_failed_clean,
    precommit_failed_ambiguous_usable,
    precommit_failed_ambiguous_unusable,
    begin_authority_commit,
    takeover_sent_unknown,
    controller_evidenced,
    authority_conflict,
    gone_positive,
    begin_retry_wait_release,
    retry_direct_granted,
    retry_expired,
    begin_publish,
    publish_new,
    freeze_with_reserved_retry,
    end_runtime,
    prepare_unavailable,
    retry_unavailable,
    close_requested,
    reconnect_quiesced_for_close,
    close_timed_out,
    abandon_to_inventory,
};

pub const Event = union(EventTag) {
    begin_prepare: Work,
    observer_staged: void,
    begin_mutation_seal: void,
    seal_clean: void,
    seal_ambiguous: void,
    precommit_failed_clean: void,
    precommit_failed_ambiguous_usable: void,
    precommit_failed_ambiguous_unusable: RetryReservation,
    begin_authority_commit: void,
    takeover_sent_unknown: void,
    controller_evidenced: void,
    authority_conflict: void,
    gone_positive: void,
    begin_retry_wait_release: RetryWait,
    retry_direct_granted: void,
    retry_expired: ClockEvidence,
    begin_publish: void,
    publish_new: void,
    freeze_with_reserved_retry: RetryReservation,
    end_runtime: void,
    prepare_unavailable: Unavailable,
    retry_unavailable: UnavailableRetry,
    close_requested: CloseIntent,
    reconnect_quiesced_for_close: CloseQuiescence,
    close_timed_out: ClockEvidence,
    abandon_to_inventory: void,
};

pub const Decision = enum(u8) {
    prepare_candidate,
    retain_staged_observer,
    seal_mutations,
    retain_clean_seal,
    retain_ambiguous_seal,
    abort_candidate_restore_old,
    abort_candidate_restore_old_with_paused_notice,
    abort_candidate_freeze_old,
    start_authority_commit,
    retain_takeover_unknown,
    retain_controller_evidence,
    retain_authority_conflict,
    retain_gone_evidence,
    wait_for_direct_release,
    resume_with_direct_grant,
    publish_retry_conflict,
    start_publication,
    publish_new_and_open,
    publish_unavailable_with_retry,
    publish_ended,
    publish_job_unavailable,
    retry_job,
    finish_job,
    publish_termination_pending,
    close_preserve_old,
    close_preserve_old_with_paused_notice,
    close_publish_new,
    close_freeze_with_retry,
    close_finish_terminal,
    publish_termination_unconfirmed,
    abandon_shell_to_inventory,
};

pub const Result = struct { state: State, decision: Decision };
pub const Error = error{IllegalTransition};

pub const TerminalSummary = struct {
    job_generation: u64,
    total: u32,
    published_new: u32,
    frozen_unavailable: u32,
    ended: u32,
    retry_reserved: u32,

    pub fn valid(self: TerminalSummary) bool {
        if (self.job_generation == 0 or self.total == 0 or
            self.retry_reserved != self.frozen_unavailable) return false;
        const live = std.math.add(u32, self.published_new, self.frozen_unavailable) catch return false;
        const terminal = std.math.add(u32, live, self.ended) catch return false;
        return terminal == self.total;
    }
};

pub fn valid(state: State) bool {
    if (state.shell_generation == 0 or !phaseValid(state.phase) or
        !phaseMatchesShell(state)) return false;
    if (state.retry) |retry| {
        if (!retry.valid() or retry.shell_generation != state.shell_generation or
            state.local != .frozen_unavailable) return false;
    }
    if (!closeValid(state.close) or !closeMatchesShell(state.close, state.shell_generation))
        return false;
    if (state.close == .abandoned_to_inventory and
        (state.local != .ended or state.mutation != .closed)) return false;
    return switch (state.phase) {
        .healthy => stateValidAtRest(state),
        .preparing => (state.ledger == .old_valid or state.ledger == .staged_observer) and
            state.local == .published_old and mutationBeforeCommit(state) and state.retry == null,
        .mutation_sealing => state.ledger == .staged_observer and state.local == .published_old and
            (state.mutation == .sealing or state.mutation == .sealed_clean or
                state.mutation == .sealed_ambiguous or mutationClosedByClose(state)) and
            state.retry == null,
        .authority_committing, .retry_wait_release => state.local == .published_old and
            (state.mutation == .sealed_clean or state.mutation == .sealed_ambiguous or
                mutationClosedByClose(state)) and state.retry == null,
        .publishing => switch (state.local) {
            .published_old => (state.mutation == .sealed_clean or
                state.mutation == .sealed_ambiguous or mutationClosedByClose(state)) and
                state.retry == null,
            .published_new => state.ledger == .new_controller_evidenced and
                state.mutation == .open and state.retry == null,
            .frozen_unavailable => frozenLedgerValid(state.ledger) and
                state.mutation == .closed and state.retry != null,
            .ended => state.ledger == .gone_positive and state.mutation == .closed and
                state.retry == null,
        },
        .unavailable => state.ledger == .old_valid and state.local == .published_old and
            mutationBeforeCommit(state) and state.retry == null,
    };
}

pub fn reduce(before: State, event: Event) Error!Result {
    if (!valid(before)) return error.IllegalTransition;
    const event_tag = std.meta.activeTag(event);
    if (before.close != .none and event_tag != .reconnect_quiesced_for_close and
        event_tag != .close_timed_out and event_tag != .abandon_to_inventory)
        return error.IllegalTransition;

    var next = before;
    const decision: Decision = switch (event) {
        .begin_prepare => |work| blk: {
            const job_generation = switch (before.phase) {
                .healthy => |generation| generation,
                else => return error.IllegalTransition,
            };
            if (!work.valid() or work.job_generation != job_generation or
                work.shell_generation != before.shell_generation or
                before.local != .published_old or before.mutation != .open or
                before.close != .none) return error.IllegalTransition;
            next.phase = .{ .preparing = work };
            next.ledger = .old_valid;
            break :blk .prepare_candidate;
        },
        .observer_staged => blk: {
            if (before.phaseTag() != .preparing or before.ledger != .old_valid)
                return error.IllegalTransition;
            next.ledger = .staged_observer;
            break :blk .retain_staged_observer;
        },
        .begin_mutation_seal => blk: {
            const work = switch (before.phase) {
                .preparing => |value| value,
                else => return error.IllegalTransition,
            };
            if (before.ledger != .staged_observer or before.mutation != .open)
                return error.IllegalTransition;
            next.phase = .{ .mutation_sealing = work };
            next.mutation = .sealing;
            break :blk .seal_mutations;
        },
        .seal_clean => blk: {
            if (before.phaseTag() != .mutation_sealing or before.mutation != .sealing)
                return error.IllegalTransition;
            next.mutation = .sealed_clean;
            break :blk .retain_clean_seal;
        },
        .seal_ambiguous => blk: {
            if (before.phaseTag() != .mutation_sealing or before.mutation != .sealing)
                return error.IllegalTransition;
            next.mutation = .sealed_ambiguous;
            break :blk .retain_ambiguous_seal;
        },
        .precommit_failed_clean => blk: {
            if (before.phaseTag() != .mutation_sealing or before.mutation != .sealed_clean)
                return error.IllegalTransition;
            next.phase = .{ .healthy = jobGeneration(before.phase) };
            next.ledger = .old_valid;
            next.mutation = .open;
            break :blk .abort_candidate_restore_old;
        },
        .precommit_failed_ambiguous_usable => blk: {
            if (before.phaseTag() != .mutation_sealing or before.mutation != .sealed_ambiguous)
                return error.IllegalTransition;
            next.phase = .{ .healthy = jobGeneration(before.phase) };
            next.ledger = .old_valid;
            next.mutation = .open;
            break :blk .abort_candidate_restore_old_with_paused_notice;
        },
        .precommit_failed_ambiguous_unusable => |retry| blk: {
            if (before.phaseTag() != .mutation_sealing or before.mutation != .sealed_ambiguous)
                return error.IllegalTransition;
            if (!retry.valid() or retry.shell_generation != before.shell_generation)
                return error.IllegalTransition;
            next.phase = .{ .healthy = jobGeneration(before.phase) };
            next.ledger = .old_valid;
            next.local = .frozen_unavailable;
            next.mutation = .closed;
            next.retry = retry;
            break :blk .abort_candidate_freeze_old;
        },
        .begin_authority_commit => blk: {
            const work = switch (before.phase) {
                .mutation_sealing => |value| value,
                else => return error.IllegalTransition,
            };
            if (before.mutation != .sealed_clean and before.mutation != .sealed_ambiguous)
                return error.IllegalTransition;
            next.phase = .{ .authority_committing = work };
            break :blk .start_authority_commit;
        },
        .takeover_sent_unknown => blk: {
            if (before.phaseTag() != .authority_committing or
                before.ledger != .staged_observer) return error.IllegalTransition;
            next.ledger = .takeover_sent_unknown;
            break :blk .retain_takeover_unknown;
        },
        .controller_evidenced => blk: {
            if (before.phaseTag() != .authority_committing or
                (before.ledger != .staged_observer and
                    before.ledger != .takeover_sent_unknown)) return error.IllegalTransition;
            next.ledger = .new_controller_evidenced;
            break :blk .retain_controller_evidence;
        },
        .authority_conflict => blk: {
            if (before.phaseTag() != .authority_committing or
                (before.ledger != .staged_observer and
                    before.ledger != .takeover_sent_unknown)) return error.IllegalTransition;
            next.ledger = .authority_conflict;
            break :blk .retain_authority_conflict;
        },
        .gone_positive => blk: {
            if (before.phaseTag() != .authority_committing or
                (before.ledger != .staged_observer and
                    before.ledger != .takeover_sent_unknown)) return error.IllegalTransition;
            next.ledger = .gone_positive;
            break :blk .retain_gone_evidence;
        },
        .begin_retry_wait_release => |retry| blk: {
            const work = switch (before.phase) {
                .authority_committing => |value| value,
                else => return error.IllegalTransition,
            };
            if (!retry.valid() or !std.meta.eql(work, retry.work) or
                before.ledger != .authority_conflict) return error.IllegalTransition;
            next.phase = .{ .retry_wait_release = retry };
            break :blk .wait_for_direct_release;
        },
        .retry_direct_granted => blk: {
            const retry = switch (before.phase) {
                .retry_wait_release => |value| value,
                else => return error.IllegalTransition,
            };
            next.phase = .{ .authority_committing = retry.work };
            next.ledger = .new_controller_evidenced;
            break :blk .resume_with_direct_grant;
        },
        .retry_expired => |clock| blk: {
            const retry = switch (before.phase) {
                .retry_wait_release => |value| value,
                else => return error.IllegalTransition,
            };
            if (clock.now_ns < retry.work.deadline_ns) return error.IllegalTransition;
            next.phase = .{ .publishing = retry.work };
            next.ledger = .authority_conflict;
            break :blk .publish_retry_conflict;
        },
        .begin_publish => blk: {
            const work = switch (before.phase) {
                .authority_committing => |value| value,
                else => return error.IllegalTransition,
            };
            if (before.ledger == .staged_observer or before.ledger == .old_valid)
                return error.IllegalTransition;
            next.phase = .{ .publishing = work };
            break :blk .start_publication;
        },
        .publish_new => blk: {
            if (before.phaseTag() != .publishing or before.local != .published_old or
                before.ledger != .new_controller_evidenced)
                return error.IllegalTransition;
            next.local = .published_new;
            next.mutation = .open;
            next.shell_generation = std.math.add(u64, before.shell_generation, 1) catch
                return error.IllegalTransition;
            break :blk .publish_new_and_open;
        },
        .freeze_with_reserved_retry => |retry| blk: {
            if (before.phaseTag() != .publishing or before.local != .published_old or
                (before.ledger != .takeover_sent_unknown and before.ledger != .authority_conflict))
                return error.IllegalTransition;
            if (!retry.valid() or retry.shell_generation != before.shell_generation)
                return error.IllegalTransition;
            next.local = .frozen_unavailable;
            next.mutation = .closed;
            next.retry = retry;
            break :blk .publish_unavailable_with_retry;
        },
        .end_runtime => blk: {
            if (before.phaseTag() != .publishing or before.local != .published_old or
                before.ledger != .gone_positive)
                return error.IllegalTransition;
            next.local = .ended;
            next.mutation = .closed;
            break :blk .publish_ended;
        },
        .prepare_unavailable => |unavailable| blk: {
            const work = switch (before.phase) {
                .preparing => |value| value,
                else => return error.IllegalTransition,
            };
            if (before.phaseTag() != .preparing or before.ledger != .old_valid or
                !unavailable.valid() or unavailable.job_generation != work.job_generation or
                unavailable.shell_generation != work.shell_generation or
                unavailable.last_attempt != work.attempt or
                unavailable.last_candidate_connection_generation != work.candidate_connection_generation)
                return error.IllegalTransition;
            next.phase = .{ .unavailable = unavailable };
            break :blk .publish_job_unavailable;
        },
        .retry_unavailable => |retry| blk: {
            const unavailable = switch (before.phase) {
                .unavailable => |value| value,
                else => return error.IllegalTransition,
            };
            const next_attempt = std.math.add(u64, unavailable.last_attempt, 1) catch
                return error.IllegalTransition;
            if (!retry.work.valid() or retry.work.job_generation != unavailable.job_generation or
                retry.work.shell_generation != unavailable.shell_generation or
                retry.clock.now_ns < unavailable.retry_at_ns or
                retry.clock.now_ns > unavailable.deadline_ns or
                retry.work.deadline_ns <= retry.clock.now_ns or retry.work.attempt != next_attempt or
                retry.work.candidate_connection_generation <=
                    unavailable.last_candidate_connection_generation) return error.IllegalTransition;
            next.phase = .{ .preparing = retry.work };
            break :blk .retry_job;
        },
        .close_requested => |intent| blk: {
            if (before.close != .none or before.local == .ended) return error.IllegalTransition;
            if (!intent.valid() or intent.shell_generation != before.shell_generation)
                return error.IllegalTransition;
            next.close = .{ .termination_pending = intent };
            break :blk .publish_termination_pending;
        },
        .reconnect_quiesced_for_close => |evidence| blk: {
            if (before.close != .termination_pending and before.close != .termination_unconfirmed)
                return error.IllegalTransition;
            if (before.phaseTag() == .healthy) return error.IllegalTransition;
            if (evidence.retry) |retry| if (!retry.valid() or
                retry.shell_generation != before.shell_generation) return error.IllegalTransition;
            const generation = jobGeneration(before.phase);
            if (before.local != .published_old) {
                switch (before.local) {
                    .published_old => unreachable,
                    .published_new, .ended => if (evidence.retry != null)
                        return error.IllegalTransition,
                    .frozen_unavailable => if (!std.meta.eql(before.retry, evidence.retry))
                        return error.IllegalTransition,
                }
                next.phase = .{ .healthy = generation };
                break :blk .close_finish_terminal;
            }
            switch (before.ledger) {
                .old_valid, .staged_observer => {
                    next.phase = .{ .healthy = generation };
                    next.ledger = .old_valid;
                    next.mutation = .closed;
                    if (!evidence.old_transport_usable) {
                        const retry = evidence.retry orelse return error.IllegalTransition;
                        next.local = .frozen_unavailable;
                        next.retry = retry;
                        break :blk .close_freeze_with_retry;
                    }
                    if (evidence.retry != null) return error.IllegalTransition;
                    break :blk if (before.mutation == .sealed_ambiguous)
                        .close_preserve_old_with_paused_notice
                    else
                        .close_preserve_old;
                },
                .new_controller_evidenced => {
                    if (evidence.retry != null) return error.IllegalTransition;
                    next.phase = .{ .healthy = generation };
                    next.local = .published_new;
                    next.mutation = .closed;
                    next.shell_generation = std.math.add(u64, before.shell_generation, 1) catch
                        return error.IllegalTransition;
                    next.close = advanceCloseShell(before.close, next.shell_generation) orelse
                        return error.IllegalTransition;
                    break :blk .close_publish_new;
                },
                .takeover_sent_unknown, .authority_conflict => {
                    const retry = evidence.retry orelse return error.IllegalTransition;
                    next.phase = .{ .healthy = generation };
                    next.local = .frozen_unavailable;
                    next.mutation = .closed;
                    next.retry = retry;
                    break :blk .close_freeze_with_retry;
                },
                .gone_positive => {
                    if (evidence.retry != null) return error.IllegalTransition;
                    next.phase = .{ .healthy = generation };
                    next.local = .ended;
                    next.mutation = .closed;
                    break :blk .close_finish_terminal;
                },
            }
        },
        .close_timed_out => |clock| blk: {
            const intent = switch (before.close) {
                .termination_pending => |value| value,
                else => return error.IllegalTransition,
            };
            if (clock.now_ns < intent.deadline_ns) return error.IllegalTransition;
            next.close = .{ .termination_unconfirmed = intent };
            break :blk .publish_termination_unconfirmed;
        },
        .abandon_to_inventory => blk: {
            const intent_generation = switch (before.close) {
                .termination_pending => |intent| intent.intent_generation,
                .termination_unconfirmed => |intent| intent.intent_generation,
                else => return error.IllegalTransition,
            };
            if (before.phaseTag() != .healthy) return error.IllegalTransition;
            next.phase = .{ .healthy = jobGeneration(before.phase) };
            next.local = .ended;
            next.mutation = .closed;
            next.close = .{ .abandoned_to_inventory = intent_generation };
            next.retry = null;
            break :blk .abandon_shell_to_inventory;
        },
    };
    if (!valid(next)) return error.IllegalTransition;
    return .{ .state = next, .decision = decision };
}

pub fn completeJob(before: State, summary: TerminalSummary) Error!Result {
    if (!valid(before) or before.phaseTag() != .publishing or
        before.local == .published_old or before.close != .none or !summary.valid() or
        summary.job_generation != jobGeneration(before.phase))
        return error.IllegalTransition;
    const includes_local = switch (before.local) {
        .published_old => false,
        .published_new => summary.published_new != 0,
        .frozen_unavailable => summary.frozen_unavailable != 0,
        .ended => summary.ended != 0,
    };
    if (!includes_local) return error.IllegalTransition;
    var next = before;
    next.phase = .{ .healthy = std.math.add(u64, jobGeneration(before.phase), 1) catch
        return error.IllegalTransition };
    if (!valid(next)) return error.IllegalTransition;
    return .{ .state = next, .decision = .finish_job };
}

fn phaseValid(phase: PhaseState) bool {
    return switch (phase) {
        .healthy => |generation| generation != 0,
        .preparing, .mutation_sealing, .authority_committing, .publishing => |work| work.valid(),
        .retry_wait_release => |retry| retry.valid(),
        .unavailable => |unavailable| unavailable.valid(),
    };
}

fn phaseMatchesShell(state: State) bool {
    return switch (state.phase) {
        .healthy => true,
        .preparing, .mutation_sealing, .authority_committing => |work| work.shell_generation == state.shell_generation,
        .publishing => |work| blk: {
            if (state.local != .published_new)
                break :blk work.shell_generation == state.shell_generation;
            const next_generation = std.math.add(u64, work.shell_generation, 1) catch
                break :blk false;
            break :blk next_generation == state.shell_generation;
        },
        .retry_wait_release => |retry| retry.work.shell_generation == state.shell_generation,
        .unavailable => |unavailable| unavailable.shell_generation == state.shell_generation,
    };
}

fn jobGeneration(phase: PhaseState) u64 {
    return switch (phase) {
        .healthy => |generation| generation,
        .preparing, .mutation_sealing, .authority_committing, .publishing => |work| work.job_generation,
        .retry_wait_release => |retry| retry.work.job_generation,
        .unavailable => |unavailable| unavailable.job_generation,
    };
}

fn stateValidAtRest(state: State) bool {
    return switch (state.local) {
        .published_old => state.ledger == .old_valid and
            (state.mutation == .open or mutationClosedByClose(state)) and state.retry == null,
        .published_new => state.ledger == .new_controller_evidenced and
            (state.mutation == .open or mutationClosedByClose(state)) and state.retry == null,
        .frozen_unavailable => frozenLedgerValid(state.ledger) and
            state.mutation == .closed and state.retry != null,
        .ended => state.mutation == .closed and
            (state.ledger == .gone_positive or state.close == .abandoned_to_inventory),
    };
}

fn mutationBeforeCommit(state: State) bool {
    return state.mutation == .open or mutationClosedByClose(state);
}

fn mutationClosedByClose(state: State) bool {
    return state.mutation == .closed and state.close != .none;
}

fn closeValid(close: CloseState) bool {
    return switch (close) {
        .none => true,
        .termination_pending, .termination_unconfirmed => |intent| intent.valid(),
        .abandoned_to_inventory => |generation| generation != 0,
    };
}

fn closeMatchesShell(close: CloseState, shell_generation: u64) bool {
    return switch (close) {
        .none, .abandoned_to_inventory => true,
        .termination_pending, .termination_unconfirmed => |intent| intent.shell_generation == shell_generation,
    };
}

fn advanceCloseShell(close: CloseState, shell_generation: u64) ?CloseState {
    return switch (close) {
        .termination_pending => |intent| .{ .termination_pending = .{
            .intent_generation = intent.intent_generation,
            .shell_generation = shell_generation,
            .deadline_ns = intent.deadline_ns,
        } },
        .termination_unconfirmed => |intent| .{ .termination_unconfirmed = .{
            .intent_generation = intent.intent_generation,
            .shell_generation = shell_generation,
            .deadline_ns = intent.deadline_ns,
        } },
        else => null,
    };
}

fn allZero(bytes: []const u8) bool {
    var aggregate: u8 = 0;
    for (bytes) |byte| aggregate |= byte;
    return aggregate == 0;
}

fn frozenLedgerValid(ledger: RuntimeLedger) bool {
    return ledger == .old_valid or ledger == .takeover_sent_unknown or
        ledger == .authority_conflict or ledger == .new_controller_evidenced;
}
