//! Closed validator-command selection and child observation mapping for the live release workflow.

const std = @import("std");
const contract = @import("release_adapter_contract");
const phase = @import("release_adapter_live_workflow_phase");
const outcome = @import("release_adapter_command_outcome");

pub const Selection = enum(u8) {
    draft_authoring,
    aggregate_prepare,
    aggregate_finalize,
    publication,
    aggregate_cleanup,
};

pub const Termination = union(enum) {
    exited: u8,
    signal: u32,
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

pub const Error = error{ InvalidArguments, InvalidCommand };

pub const max_stdout_bytes: usize = 1;
pub const max_stderr_bytes: usize = "descriptor_close_failed\n".len;

pub fn select(arguments: []const []const u8) Error!Selection {
    const parsed = contract.parseArgs(arguments) catch return error.InvalidArguments;
    return switch (parsed) {
        .prepare_candidate => .draft_authoring,
        .prepare_candidate_aggregate => .aggregate_prepare,
        .finalize_candidate_aggregate => .aggregate_finalize,
        .resume_candidate_publication => .publication,
        .cleanup_candidate_aggregate => .aggregate_cleanup,
        else => error.InvalidCommand,
    };
}

pub fn stage(selection: Selection) phase.Stage {
    return switch (selection) {
        .draft_authoring => .draft_authoring,
        .aggregate_prepare => .aggregate_prepare,
        .aggregate_finalize => .aggregate_finalize,
        .publication => .publication,
        .aggregate_cleanup => .aggregate_cleanup,
    };
}

pub fn requiresToken(selection: Selection) bool {
    return switch (selection) {
        .draft_authoring, .publication, .aggregate_cleanup => true,
        .aggregate_prepare, .aggregate_finalize => false,
    };
}

pub fn requiresWorkspace(selection: Selection) bool {
    return selection == .draft_authoring;
}

pub fn classify(selection: Selection, observation: Observation) phase.Result {
    if (!observation.stdout.complete or !observation.stderr.complete or observation.stdout.bytes.len != 0)
        return .cleanup_failed;
    const code = switch (observation.termination) {
        .exited => |value| value,
        .signal, .unknown => return .cleanup_failed,
    };
    return switch (selection) {
        .draft_authoring => classifyStage3(code, observation.stderr.bytes),
        .aggregate_prepare, .aggregate_finalize => classifyAggregate(code, observation.stderr.bytes),
        .publication => classifyPublication(code, observation.stderr.bytes),
        .aggregate_cleanup => classifyCleanup(code, observation.stderr.bytes),
    };
}

fn classifyStage3(code: u8, stderr: []const u8) phase.Result {
    inline for (@typeInfo(outcome.Stage3).@"enum".fields) |field| {
        const value: outcome.Stage3 = @enumFromInt(field.value);
        if (matches(code, stderr, outcome.stage3ExitCode(value), outcome.stage3StderrLine(value))) return switch (value) {
            .success => .succeeded,
            .local_failure => .failed_before_remote_mutation,
            .audit_required => .failed,
            .cleanup_failed => .cleanup_failed,
        };
    }
    return .cleanup_failed;
}

fn classifyAggregate(code: u8, stderr: []const u8) phase.Result {
    inline for (@typeInfo(outcome.Aggregate).@"enum".fields) |field| {
        const value: outcome.Aggregate = @enumFromInt(field.value);
        if (matches(code, stderr, outcome.aggregateExitCode(value), outcome.aggregateStderrLine(value))) return switch (value) {
            .success => .succeeded,
            .audit_required => .failed,
            .cleanup_failed => .cleanup_failed,
        };
    }
    return .cleanup_failed;
}

fn classifyPublication(code: u8, stderr: []const u8) phase.Result {
    inline for (@typeInfo(outcome.Publication).@"enum".fields) |field| {
        const value: outcome.Publication = @enumFromInt(field.value);
        if (matches(code, stderr, outcome.publicationExitCode(value), outcome.publicationStderrLine(value))) return switch (value) {
            .success => .succeeded,
            .audit_required => .failed,
            .cleanup_failed => .cleanup_failed,
        };
    }
    return .cleanup_failed;
}

fn classifyCleanup(code: u8, stderr: []const u8) phase.Result {
    inline for (@typeInfo(outcome.Cleanup).@"enum".fields) |field| {
        const value: outcome.Cleanup = @enumFromInt(field.value);
        if (matches(code, stderr, outcome.cleanupExitCode(value), outcome.cleanupStderrLine(value))) return switch (value) {
            .success => .succeeded,
            .audit_required => .failed,
            .cleanup_required, .descriptor_close_failed => .cleanup_failed,
        };
    }
    return .cleanup_failed;
}

fn matches(actual_code: u8, actual_stderr: []const u8, expected_code: u8, expected_stderr: []const u8) bool {
    return actual_code == expected_code and std.mem.eql(u8, actual_stderr, expected_stderr);
}
