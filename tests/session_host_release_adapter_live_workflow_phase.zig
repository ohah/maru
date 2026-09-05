//! The trusted tag workflow must not invent release ordering in YAML.
//! These tests exhaust the pointer-free reducer that classifies every stage failure and keeps a
//! durable aggregate until the published release has passed its final attestation.

const std = @import("std");
const phase = @import("release_adapter_live_workflow_phase");

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

test "live workflow accepts only the exact eight-stage success order" {
    std.testing.refAllDecls(phase);
    var state: phase.State = .{};
    for (stages) |stage| try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
    try std.testing.expectEqual(phase.Outcome.succeeded, state.outcome);
    try std.testing.expectEqual(@as(?phase.Stage, null), state.expectedStage());
    try std.testing.expect(state.published);
    try std.testing.expect(!state.aggregateRetained());
}

test "every successful prefix publishes only its derived authority" {
    var state: phase.State = .{};
    for (stages, 0..) |stage, index| {
        try std.testing.expectEqual(stage, state.expectedStage().?);
        try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
        try std.testing.expectEqual(index >= 4 and index < 7, state.aggregateRetained());
        try std.testing.expectEqual(index >= 6, state.published);
        try std.testing.expectEqual(if (index == 7) phase.Outcome.succeeded else .active, state.outcome);
    }
}

test "every stage failure has one closed terminal classification" {
    for (stages, 0..) |failed_stage, failed_index| {
        var state: phase.State = .{};
        for (stages[0..failed_index]) |stage|
            try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
        try phase.apply(&state, .{ .stage = failed_stage, .result = .failed });
        const expected: phase.Outcome = if (failed_index < 2)
            .local_failure
        else if (failed_index < 7)
            .audit_required
        else
            .cleanup_required;
        try std.testing.expectEqual(expected, state.outcome);
        try std.testing.expectEqual(failed_index >= 5, state.aggregateRetained());
        try std.testing.expectEqual(failed_index == 7, state.published);
    }
}

test "cleanup failure preserves local authority before draft and audit graph after draft" {
    for (stages, 0..) |failed_stage, failed_index| {
        var state: phase.State = .{};
        for (stages[0..failed_index]) |stage|
            try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
        try phase.apply(&state, .{ .stage = failed_stage, .result = .cleanup_failed });
        const expected: phase.Outcome = if (failed_index < 2 or failed_index == 7)
            .cleanup_required
        else
            .audit_required;
        try std.testing.expectEqual(expected, state.outcome);
        try std.testing.expectEqual(failed_index >= 5, state.aggregateRetained());
        try std.testing.expectEqual(failed_index == 7, state.published);
    }
}

test "every skip reverse and duplicate event at every prefix is mutation zero" {
    var state: phase.State = .{};
    for (stages) |expected| {
        for (stages) |candidate| {
            if (candidate == expected) continue;
            inline for (.{ phase.Result.succeeded, .failed, .cleanup_failed }) |result| {
                const before = state;
                try std.testing.expectError(error.UnexpectedStage, phase.apply(&state, .{ .stage = candidate, .result = result }));
                try std.testing.expectEqualDeep(before, state);
            }
        }
        try phase.apply(&state, .{ .stage = expected, .result = .succeeded });
    }
}

test "terminal failure rejects replay without changing evidence" {
    var state: phase.State = .{};
    try phase.apply(&state, .{ .stage = .candidate_pinning, .result = .failed });
    const before = state;
    try std.testing.expectError(error.TerminalState, phase.apply(&state, .{ .stage = .candidate_pinning, .result = .succeeded }));
    try std.testing.expectEqualDeep(before, state);

    var succeeded: phase.State = .{};
    for (stages) |stage| try phase.apply(&succeeded, .{ .stage = stage, .result = .succeeded });
    const success_before = succeeded;
    try std.testing.expectError(error.TerminalState, phase.apply(&succeeded, .{ .stage = .aggregate_cleanup, .result = .succeeded }));
    try std.testing.expectEqualDeep(success_before, succeeded);
}

test "every noncanonical state is rejected before event mutation" {
    const outcomes = [_]phase.Outcome{ .active, .succeeded, .local_failure, .audit_required, .cleanup_required };
    for (0..10) |next| {
        for (outcomes) |outcome| {
            for (0..8) |bits| {
                var state: phase.State = .{
                    .next_index = @intCast(next),
                    .outcome = outcome,
                    .draft_mutation_started = bits & 1 != 0,
                    .aggregate_present = bits & 2 != 0,
                    .published = bits & 4 != 0,
                };
                if (state.isCanonical()) continue;
                const before = state;
                try std.testing.expectError(error.InvalidState, phase.apply(&state, .{
                    .stage = .candidate_pinning,
                    .result = .succeeded,
                }));
                try std.testing.expectEqualDeep(before, state);
            }
        }
    }
}

test "aggregate cleanup cannot precede publication attestation" {
    var state: phase.State = .{};
    for (stages[0..6]) |stage| try phase.apply(&state, .{ .stage = stage, .result = .succeeded });
    try std.testing.expect(state.aggregateRetained());
    const before = state;
    try std.testing.expectError(error.UnexpectedStage, phase.apply(&state, .{ .stage = .aggregate_cleanup, .result = .succeeded }));
    try std.testing.expectEqualDeep(before, state);
}

test "all failures after aggregate prepare retain its cleanup authority" {
    inline for (.{ phase.Stage.aggregate_finalize, .publication, .aggregate_cleanup }) |failed_stage| {
        var state: phase.State = .{};
        while (state.expectedStage().? != failed_stage)
            try phase.apply(&state, .{ .stage = state.expectedStage().?, .result = .succeeded });
        try phase.apply(&state, .{ .stage = failed_stage, .result = .failed });
        try std.testing.expect(state.aggregateRetained());
    }
}

test "workflow state is pointer-free value data" {
    try expectPointerFree(phase.State);
    try expectPointerFree(phase.Event);
    try std.testing.expect(@sizeOf(phase.State) <= 8);
}

test "stage inventory and canonical order cannot drift independently" {
    const fields = @typeInfo(phase.Stage).@"enum".fields;
    try std.testing.expectEqual(stages.len, fields.len);
    for (stages, 0..) |stage, index| {
        try std.testing.expectEqual(index, @intFromEnum(stage));
        try std.testing.expectEqualStrings(fields[index].name, @tagName(stage));
    }
}

fn expectPointerFree(comptime T: type) !void {
    switch (@typeInfo(T)) {
        .pointer => return error.PointerField,
        .optional => |info| {
            try expectPointerFree(info.child);
        },
        .array => |info| {
            try expectPointerFree(info.child);
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| try expectPointerFree(field.type);
        },
        .@"union" => |info| {
            inline for (info.fields) |field| try expectPointerFree(field.type);
        },
        else => {},
    }
}
