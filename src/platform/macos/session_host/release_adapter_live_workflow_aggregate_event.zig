//! Closed process-observation adapter for aggregate stages of the trusted release workflow.
//!
//! A command selects its own reducer stage. Captured output is transient evidence only: no path,
//! credential, diagnostic text, or process identifier reaches the pointer-free workflow state.

const std = @import("std");
const phase = @import("release_adapter_live_workflow_phase");
const command_outcome = @import("release_adapter_candidate_aggregate_command_outcome");
const contract = @import("release_adapter_contract");

pub const Command = std.meta.Tag(contract.Command);
pub const Error = phase.Error || error{InvalidCommand};

pub const Termination = union(enum) {
    exited: u8,
    signal: u32,
    stopped: u32,
    unknown: u32,
};

pub const CapturedStream = struct {
    bytes: []const u8,
    complete: bool,
};

pub const Observation = struct {
    termination: Termination,
    stdout: CapturedStream,
    stderr: CapturedStream,
};

pub fn stageFor(command: Command) error{InvalidCommand}!phase.Stage {
    return switch (command) {
        .prepare_candidate_aggregate => .aggregate_prepare,
        .finalize_candidate_aggregate => .aggregate_finalize,
        else => error.InvalidCommand,
    };
}

pub fn eventFor(command: Command, observation: Observation) error{InvalidCommand}!phase.Event {
    const stage = try stageFor(command);
    return .{ .stage = stage, .result = classify(observation) };
}

pub fn applyObservation(state: *phase.State, command: Command, observation: Observation) Error!void {
    const stage = try stageFor(command);
    return phase.apply(state, .{ .stage = stage, .result = classify(observation) });
}

fn classify(observation: Observation) phase.Result {
    if (!observation.stdout.complete or !observation.stderr.complete) return .cleanup_failed;
    if (observation.stdout.bytes.len != 0) return .cleanup_failed;

    const code = switch (observation.termination) {
        .exited => |value| value,
        .signal, .stopped, .unknown => return .cleanup_failed,
    };
    inline for (@typeInfo(command_outcome.Outcome).@"enum".fields) |field| {
        const outcome: command_outcome.Outcome = @enumFromInt(field.value);
        if (code == command_outcome.exitCode(outcome) and
            std.mem.eql(u8, observation.stderr.bytes, command_outcome.stderrLine(outcome)))
        {
            return switch (outcome) {
                .success => .succeeded,
                .audit_required => .failed,
                .cleanup_failed => .cleanup_failed,
            };
        }
    }
    return .cleanup_failed;
}

comptime {
    if (@typeInfo(Command).@"enum".fields.len != 8)
        @compileError("release workflow command inventory drift");
}
