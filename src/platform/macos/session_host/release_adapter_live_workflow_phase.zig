//! Closed logical ordering for the trusted session-host release workflow.
//!
//! Concrete owners prove each side effect before reporting an event here. This reducer deliberately
//! stores no pathname, credential, process result, or GitHub identifier that could be mistaken for
//! authority after a process or Actions-step boundary.

pub const Stage = enum(u8) {
    candidate_pinning,
    candidate_attestation,
    draft_authoring,
    authored_attestation,
    aggregate_prepare,
    aggregate_finalize,
    publication,
    aggregate_cleanup,
};

pub const Result = enum(u8) { succeeded, failed, cleanup_failed };

pub const Event = struct {
    stage: Stage,
    result: Result,
};

pub const Outcome = enum(u8) {
    active,
    succeeded,
    local_failure,
    audit_required,
    cleanup_required,
};

pub const State = struct {
    next_index: u8 = 0,
    outcome: Outcome = .active,
    draft_mutation_started: bool = false,
    aggregate_present: bool = false,
    published: bool = false,

    pub fn expectedStage(self: @This()) ?Stage {
        if (!self.isCanonical() or self.outcome != .active) return null;
        return ordered_stages[self.next_index];
    }

    pub fn aggregateRetained(self: @This()) bool {
        return self.aggregate_present;
    }

    pub fn isCanonical(self: @This()) bool {
        if (self.next_index > ordered_stages.len) return false;
        return switch (self.outcome) {
            .active => self.next_index < ordered_stages.len and
                self.draft_mutation_started == (self.next_index >= 3) and
                self.aggregate_present == (self.next_index >= 5) and
                self.published == (self.next_index >= 7),
            .succeeded => self.next_index == ordered_stages.len and self.draft_mutation_started and
                !self.aggregate_present and self.published,
            .local_failure => self.next_index < 2 and !self.draft_mutation_started and
                !self.aggregate_present and !self.published,
            .audit_required => self.next_index >= 2 and self.next_index < 7 and self.draft_mutation_started and
                self.aggregate_present == (self.next_index >= 5) and !self.published,
            .cleanup_required => (self.next_index < 2 and !self.draft_mutation_started and
                !self.aggregate_present and !self.published) or
                (self.next_index == 7 and self.draft_mutation_started and self.aggregate_present and self.published),
        };
    }
};

pub const Error = error{ InvalidState, UnexpectedStage, TerminalState };

const ordered_stages = [_]Stage{
    .candidate_pinning,
    .candidate_attestation,
    .draft_authoring,
    .authored_attestation,
    .aggregate_prepare,
    .aggregate_finalize,
    .publication,
    .aggregate_cleanup,
};

comptime {
    const fields = @typeInfo(Stage).@"enum".fields;
    if (fields.len != ordered_stages.len) @compileError("live workflow stage inventory drift");
    for (ordered_stages, 0..) |stage, index| {
        if (@intFromEnum(stage) != index or fields[index].value != index)
            @compileError("live workflow stage order drift");
    }
}

pub fn apply(state: *State, event: Event) Error!void {
    if (!state.isCanonical()) return error.InvalidState;
    if (state.outcome != .active) return error.TerminalState;
    const expected = state.expectedStage() orelse return error.TerminalState;
    if (event.stage != expected) return error.UnexpectedStage;

    // Draft creation is the first remote mutation. Even a failed concrete owner may have created
    // remote state, so every failure from this attempted stage onward requires human audit.
    if (event.stage == .draft_authoring) state.draft_mutation_started = true;

    if (event.result != .succeeded) {
        state.outcome = if (!state.draft_mutation_started)
            if (event.result == .cleanup_failed) .cleanup_required else .local_failure
        else if (event.stage == .aggregate_cleanup)
            .cleanup_required
        else
            .audit_required;
        return;
    }

    switch (event.stage) {
        .aggregate_prepare => state.aggregate_present = true,
        .publication => state.published = true,
        .aggregate_cleanup => {
            state.aggregate_present = false;
            state.outcome = .succeeded;
        },
        else => {},
    }
    state.next_index += 1;
}
