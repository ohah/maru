//! Official GitHub Release validator executable.
//!
//! Success is observable only through the command's exclusive summary pathname. This process does
//! not emit credentials on stdout and never falls back between phase drivers. The stage-8 cleanup
//! command alone emits its non-authoritative timing record there.

const std = @import("std");
const manifest = @import("release_manifest");
const contract = @import("release_adapter_contract");
const bootstrap_mod = @import("release_adapter_executable_bootstrap");
const token_environment = @import("release_adapter_token_environment");
const github_transport = @import("release_adapter_github_transport");
const attestation = @import("release_adapter_github_attestation");
const compatibility = @import("release_adapter_github_current_compatibility");
const apple_transport = @import("release_adapter_apple_transport");
const pre_publish_product = @import("release_adapter_pre_publish_product");
const verify_predecessor_product = @import("release_adapter_verify_predecessor_product");
const candidate_release_driver = @import("release_adapter_candidate_release_driver");
const candidate_stage3_command = @import("release_adapter_candidate_stage3_preparation_command");
const candidate_resume_publication_command = @import("release_adapter_candidate_resume_publication_command");
const candidate_published_cleanup_command = @import("release_adapter_candidate_published_cleanup_command");
const candidate_aggregate_process = @import("release_adapter_candidate_aggregate_process");
const builtin = @import("builtin");

pub const phase_budget_ns: i128 = 20 * std.time.ns_per_min;
pub const max_command_args: usize = contract.max_command_args;
pub const github_capture_bytes: usize = github_transport.max_capture_bytes;
pub const manifest_capture_bytes: usize = manifest.max_manifest_bytes;
pub const attestation_capture_bytes: usize = attestation.max_response_bytes;
pub const compatibility_capture_bytes: usize = compatibility.max_probe_bytes;

pub const Storage = struct {
    github_response: [github_capture_bytes]u8 = undefined,
    manifest_download: [manifest_capture_bytes]u8 = undefined,
    attestation: [attestation_capture_bytes]u8 = undefined,
    compatibility: [compatibility_capture_bytes]u8 = undefined,
    apple: apple_transport.Storage = undefined,
    candidate: candidate_release_driver.Execution = .{},
    stage3: candidate_stage3_command.Execution = .{},
    resume_publication: candidate_resume_publication_command.Execution = .{},
    published_cleanup: candidate_published_cleanup_command.Execution = .{},
    aggregate_process: candidate_aggregate_process.Storage = .{},
};

const CurrentBootstrapper = struct {
    pub fn load(_: *@This(), allocator: std.mem.Allocator, args: []const []const u8, result: *bootstrap_mod.Bootstrap) !void {
        try bootstrap_mod.current(allocator, args, result);
    }
};

const CurrentTokenReader = struct {
    pub fn read(_: *@This()) ![]const u8 {
        return token_environment.readCurrent();
    }
};

const ProductDrivers = struct {
    pub fn prePublish(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        var execution: pre_publish_product.Execution = .{};
        pre_publish_product.run(io, allocator, bootstrap, token, budget_ns, .{
            .github_response = &storage.github_response,
            .manifest_download = &storage.manifest_download,
            .attestation = &storage.attestation,
            .compatibility = &storage.compatibility,
        }, &storage.apple, &execution) catch |err| {
            return settleProductFailure(&execution, err);
        };
    }

    pub fn verifyPredecessor(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        var execution: verify_predecessor_product.Execution = .{};
        verify_predecessor_product.run(io, allocator, bootstrap, token, budget_ns, .{
            .github_response = &storage.github_response,
            .attestation = &storage.attestation,
        }, &execution) catch |err| {
            return settleProductFailure(&execution, err);
        };
    }

    pub fn publishCandidate(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        return candidate_release_driver.run(
            io,
            allocator,
            bootstrap,
            token,
            storage.github_response[0..candidate_release_driver.max_scratch_bytes],
            budget_ns,
            &storage.candidate,
        );
    }

    pub fn prepareCandidate(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        const outcome = candidate_stage3_command.runOutcome(
            io,
            allocator,
            bootstrap,
            token,
            storage.github_response[0..candidate_stage3_command.max_scratch_bytes],
            budget_ns,
            &storage.stage3,
        );
        return switch (outcome) {
            .success => {},
            .local_failure => error.Stage3LocalFailure,
            .audit_required => error.Stage3AuditRequired,
            .cleanup_failed => error.Stage3CleanupFailed,
        };
    }

    pub fn resumeCandidatePublication(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        token: []const u8,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        const outcome = candidate_resume_publication_command.runOutcome(
            io,
            allocator,
            bootstrap,
            token,
            storage.github_response[0..candidate_resume_publication_command.max_response_bytes],
            budget_ns,
            &storage.resume_publication,
        );
        return switch (outcome) {
            .success => {},
            .audit_required => error.ResumePublicationAuditRequired,
            .cleanup_failed => error.ResumePublicationCleanupFailed,
        };
    }

    pub fn cleanupCandidateAggregate(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        tokens: anytype,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        const outcome = candidate_published_cleanup_command.runOutcome(
            io,
            allocator,
            bootstrap,
            tokens,
            storage.github_response[0..candidate_published_cleanup_command.max_response_bytes],
            budget_ns,
            &storage.published_cleanup,
        );
        if (outcome == .success) {
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
            const stdout = &stdout_file_writer.interface;
            try stdout.writeAll(storage.published_cleanup.timingLine());
            try stdout.flush();
            return;
        }
        return switch (outcome) {
            .success => unreachable,
            .audit_required => error.PublishedCleanupAuditRequired,
            .cleanup_required => error.PublishedCleanupRequired,
            .descriptor_close_failed => error.PublishedCleanupDescriptorCloseFailed,
        };
    }

    pub fn prepareCandidateAggregate(
        _: *@This(),
        _: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        if (budget_ns != phase_budget_ns) return error.InvalidBudget;
        try candidate_aggregate_process.prepare(allocator, bootstrap, &storage.aggregate_process);
    }

    pub fn finalizeCandidateAggregate(
        _: *@This(),
        io: std.Io,
        allocator: std.mem.Allocator,
        bootstrap: *bootstrap_mod.Bootstrap,
        budget_ns: i128,
        storage: *Storage,
    ) !void {
        try candidate_aggregate_process.finalize(io, allocator, bootstrap, budget_ns, &storage.aggregate_process);
    }
};

fn settleProductFailure(execution: anytype, original: anyerror) anyerror {
    if (execution.owner != null) execution.retryCleanup() catch return error.CleanupFailed;
    return original;
}

pub const testing_api = if (builtin.is_test) struct {
    pub fn settleFailure(execution: anytype, original: anyerror) anyerror {
        return settleProductFailure(execution, original);
    }

    pub fn appendArgument(values: *[max_command_args][]const u8, count: *usize, value: []const u8) !void {
        return appendArgumentImpl(values, count, value);
    }
} else struct {};

pub fn executeWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    storage: *Storage,
    bootstrapper: anytype,
    tokens: anytype,
    drivers: anytype,
) !void {
    var bootstrap: bootstrap_mod.Bootstrap = .{};
    try bootstrapper.load(allocator, args, &bootstrap);
    if (bootstrap.owner != &bootstrap) return error.InvalidBootstrap;
    switch (bootstrap.command) {
        .pre_publish => try drivers.prePublish(io, allocator, &bootstrap, try tokens.read(), phase_budget_ns, storage),
        .verify_predecessor => try drivers.verifyPredecessor(io, allocator, &bootstrap, try tokens.read(), phase_budget_ns, storage),
        .publish_candidate => try drivers.publishCandidate(io, allocator, &bootstrap, try tokens.read(), phase_budget_ns, storage),
        .prepare_candidate => try drivers.prepareCandidate(io, allocator, &bootstrap, try tokens.read(), phase_budget_ns, storage),
        .prepare_candidate_aggregate => try drivers.prepareCandidateAggregate(io, allocator, &bootstrap, phase_budget_ns, storage),
        .finalize_candidate_aggregate => try drivers.finalizeCandidateAggregate(io, allocator, &bootstrap, phase_budget_ns, storage),
        .resume_candidate_publication => try drivers.resumeCandidatePublication(io, allocator, &bootstrap, try tokens.read(), phase_budget_ns, storage),
        .cleanup_candidate_aggregate => try drivers.cleanupCandidateAggregate(io, allocator, &bootstrap, tokens, phase_budget_ns, storage),
    }
}

pub fn runCurrent(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const storage = try allocator.create(Storage);
    defer allocator.destroy(storage);
    storage.* = .{};
    try runCurrentWithStorage(io, allocator, args, storage);
}

fn runCurrentWithStorage(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, storage: *Storage) !void {
    var bootstrapper = CurrentBootstrapper{};
    var tokens = CurrentTokenReader{};
    var drivers = ProductDrivers{};
    try executeWith(io, allocator, args, storage, &bootstrapper, &tokens, &drivers);
}

pub fn main(init: std.process.Init) !void {
    var values: [max_command_args][]const u8 = undefined;
    var count: usize = 0;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |value| {
        appendArgumentImpl(&values, &count, value) catch |err| {
            if (count != 0 and std.mem.eql(u8, values[0], "prepare-candidate"))
                finishStage3(.local_failure);
            if (count != 0 and std.mem.eql(u8, values[0], "resume-candidate-publication"))
                finishResumePublication(.audit_required);
            if (count != 0 and std.mem.eql(u8, values[0], "cleanup-candidate-aggregate"))
                finishPublishedCleanup(.audit_required);
            if (count != 0 and isAggregateCommand(values[0]))
                finishAggregateCommand(.audit_required);
            return err;
        };
    }
    const storage = init.gpa.create(Storage) catch {
        if (count != 0 and isAggregateCommand(values[0]))
            finishAggregateCommand(.audit_required);
        return error.OutOfMemory;
    };
    defer init.gpa.destroy(storage);
    storage.* = .{};
    runCurrentWithStorage(init.io, init.gpa, values[0..count], storage) catch |err| {
        const outcome: candidate_stage3_command.Outcome = switch (err) {
            error.Stage3AuditRequired => .audit_required,
            error.Stage3CleanupFailed => .cleanup_failed,
            else => .local_failure,
        };
        if (count != 0 and std.mem.eql(u8, values[0], "prepare-candidate"))
            finishStage3(outcome);
        if (count != 0 and std.mem.eql(u8, values[0], "resume-candidate-publication")) {
            const resume_outcome: candidate_resume_publication_command.Outcome = switch (err) {
                error.ResumePublicationCleanupFailed => .cleanup_failed,
                else => .audit_required,
            };
            finishResumePublication(resume_outcome);
        }
        if (count != 0 and std.mem.eql(u8, values[0], "cleanup-candidate-aggregate")) {
            const cleanup_outcome: candidate_published_cleanup_command.Outcome = switch (err) {
                error.PublishedCleanupRequired => .cleanup_required,
                error.PublishedCleanupDescriptorCloseFailed => .descriptor_close_failed,
                else => .audit_required,
            };
            finishPublishedCleanup(cleanup_outcome);
        }
        if (count != 0 and isAggregateCommand(values[0]))
            finishAggregateCommand(candidate_aggregate_process.settleFailure(&storage.aggregate_process));
        return err;
    };
    if (count != 0 and std.mem.eql(u8, values[0], "prepare-candidate"))
        finishStage3(.success);
    if (count != 0 and std.mem.eql(u8, values[0], "resume-candidate-publication"))
        finishResumePublication(.success);
    if (count != 0 and std.mem.eql(u8, values[0], "cleanup-candidate-aggregate"))
        finishPublishedCleanup(.success);
    if (count != 0 and isAggregateCommand(values[0]))
        finishAggregateCommand(.success);
}

fn isAggregateCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "prepare-candidate-aggregate") or
        std.mem.eql(u8, command, "finalize-candidate-aggregate");
}

fn appendArgumentImpl(values: *[max_command_args][]const u8, count: *usize, value: []const u8) !void {
    if (count.* == values.len) return error.TooManyArguments;
    values[count.*] = value;
    count.* += 1;
}

fn finishStage3(outcome: candidate_stage3_command.Outcome) noreturn {
    std.debug.print("{s}", .{candidate_stage3_command.stderrLine(outcome)});
    std.process.exit(candidate_stage3_command.exitCode(outcome));
}

fn finishAggregateCommand(outcome: candidate_aggregate_process.Outcome) noreturn {
    std.debug.print("{s}", .{candidate_aggregate_process.stderrLine(outcome)});
    std.process.exit(candidate_aggregate_process.exitCode(outcome));
}

fn finishResumePublication(outcome: candidate_resume_publication_command.Outcome) noreturn {
    std.debug.print("{s}", .{candidate_resume_publication_command.stderrLine(outcome)});
    std.process.exit(candidate_resume_publication_command.exitCode(outcome));
}

fn finishPublishedCleanup(outcome: candidate_published_cleanup_command.Outcome) noreturn {
    std.debug.print("{s}", .{candidate_published_cleanup_command.stderrLine(outcome)});
    std.process.exit(candidate_published_cleanup_command.exitCode(outcome));
}
