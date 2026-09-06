//! Stage-5/6 child output becomes a reducer event only through one closed tuple decoder.

const std = @import("std");
const phase = @import("release_adapter_live_workflow_phase");
const mapping = @import("release_adapter_live_workflow_aggregate_event");
const contract = @import("release_adapter_contract");

const Command = std.meta.Tag(contract.Command);
const commands = [_]Command{ .prepare_candidate_aggregate, .finalize_candidate_aggregate };
const outcomes = [_]struct { code: u8, line: []const u8, result: phase.Result }{
    .{ .code = 0, .line = "success\n", .result = .succeeded },
    .{ .code = 21, .line = "audit_required\n", .result = .failed },
    .{ .code = 22, .line = "cleanup_failed\n", .result = .cleanup_failed },
};

fn complete(bytes: []const u8) mapping.CapturedStream {
    return .{ .bytes = bytes, .complete = true };
}

fn observation(code: u8, stdout: []const u8, stderr: []const u8) mapping.Observation {
    return .{
        .termination = .{ .exited = code },
        .stdout = complete(stdout),
        .stderr = complete(stderr),
    };
}

fn stateAt(command: Command) !phase.State {
    const target: phase.Stage = switch (command) {
        .prepare_candidate_aggregate => .aggregate_prepare,
        .finalize_candidate_aggregate => .aggregate_finalize,
        else => unreachable,
    };
    var state: phase.State = .{};
    while (state.expectedStage().? != target)
        try phase.apply(&state, .{ .stage = state.expectedStage().?, .result = .succeeded });
    return state;
}

const stages = [_]phase.Stage{
    .candidate_pinning,
    .candidate_attestation,
    .draft_authoring,
    .authored_attestation,
    .aggregate_prepare,
    .aggregate_finalize,
    .publication,
    .aggregate_cleanup,
};

fn stateAtIndex(index: usize) !phase.State {
    var state: phase.State = .{};
    for (stages[0..index]) |stage|
        try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
    return state;
}

test "aggregate commands derive exactly their reducer stage" {
    try std.testing.expectEqual(phase.Stage.aggregate_prepare, try mapping.stageFor(.prepare_candidate_aggregate));
    try std.testing.expectEqual(phase.Stage.aggregate_finalize, try mapping.stageFor(.finalize_candidate_aggregate));
}

test "every non-aggregate release command is rejected before observation mapping" {
    const non_aggregate = [_]Command{
        .pre_publish,
        .verify_predecessor,
        .publish_candidate,
        .prepare_candidate,
        .resume_candidate_publication,
        .cleanup_candidate_aggregate,
    };
    for (non_aggregate) |command| {
        try std.testing.expectError(error.InvalidCommand, mapping.stageFor(command));
        try std.testing.expectError(error.InvalidCommand, mapping.eventFor(command, observation(0, "", "success\n")));
        var state: phase.State = .{};
        const before = state;
        try std.testing.expectError(error.InvalidCommand, mapping.applyObservation(&state, command, observation(0, "", "success\n")));
        try std.testing.expectEqualDeep(before, state);
    }
}

test "each canonical exit and stderr tuple maps to its closed result" {
    for (commands) |command| for (outcomes) |row| {
        const event = try mapping.eventFor(command, observation(row.code, "", row.line));
        try std.testing.expectEqual(try mapping.stageFor(command), event.stage);
        try std.testing.expectEqual(row.result, event.result);
    };
}

test "every contradictory exit and stderr pair becomes cleanup failed" {
    for (commands) |command| for (outcomes, 0..) |exit_row, exit_index| for (outcomes, 0..) |stderr_row, stderr_index| {
        if (exit_index == stderr_index) continue;
        const event = try mapping.eventFor(command, observation(exit_row.code, "", stderr_row.line));
        try std.testing.expectEqual(phase.Result.cleanup_failed, event.result);
    };
}

test "unknown and non-exit termination become cleanup failed" {
    const terminations = [_]mapping.Termination{
        .{ .exited = 1 },
        .{ .exited = 23 },
        .{ .signal = 9 },
        .{ .stopped = 19 },
        .{ .unknown = 255 },
    };
    for (commands) |command| for (terminations) |termination| {
        const event = try mapping.eventFor(command, .{
            .termination = termination,
            .stdout = complete(""),
            .stderr = complete("success\n"),
        });
        try std.testing.expectEqual(phase.Result.cleanup_failed, event.result);
    };
}

test "stdout and stderr framing drift become cleanup failed" {
    const malformed = [_]mapping.Observation{
        observation(0, "unexpected", "success\n"),
        observation(0, "\n", "success\n"),
        observation(0, "", "success"),
        observation(0, "", "success\ntrailing"),
        observation(0, "", ""),
    };
    for (commands) |command| for (malformed) |value|
        try std.testing.expectEqual(phase.Result.cleanup_failed, (try mapping.eventFor(command, value)).result);
}

test "incomplete bounded capture becomes cleanup failed without inspecting bytes" {
    for (commands) |command| {
        var stdout_incomplete = observation(0, "", "success\n");
        stdout_incomplete.stdout.complete = false;
        try std.testing.expectEqual(phase.Result.cleanup_failed, (try mapping.eventFor(command, stdout_incomplete)).result);

        var stderr_incomplete = observation(0, "", "success\n");
        stderr_incomplete.stderr.complete = false;
        try std.testing.expectEqual(phase.Result.cleanup_failed, (try mapping.eventFor(command, stderr_incomplete)).result);
    }
}

test "application accepts only command-derived stage across every workflow prefix" {
    for (commands) |command| {
        const expected_index: usize = switch (command) {
            .prepare_candidate_aggregate => 4,
            .finalize_candidate_aggregate => 5,
            else => unreachable,
        };
        for (0..stages.len + 1) |prefix| {
            var state = try stateAtIndex(prefix);
            if (prefix == expected_index) {
                try mapping.applyObservation(&state, command, observation(0, "", "success\n"));
                try std.testing.expectEqual(phase.Outcome.active, state.outcome);
                continue;
            }
            const before = state;
            const expected_error = if (prefix == stages.len) error.TerminalState else error.UnexpectedStage;
            try std.testing.expectError(expected_error, mapping.applyObservation(&state, command, observation(0, "", "success\n")));
            try std.testing.expectEqualDeep(before, state);
        }

        var terminal = try stateAt(command);
        try mapping.applyObservation(&terminal, command, observation(21, "", "audit_required\n"));
        const terminal_before = terminal;
        try std.testing.expectError(error.TerminalState, mapping.applyObservation(&terminal, command, observation(0, "", "success\n")));
        try std.testing.expectEqualDeep(terminal_before, terminal);
    }
}
