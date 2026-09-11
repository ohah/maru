//! Protected upgrade profile to authenticated predecessor and signed execution composition.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const context_mod = @import("release_adapter_context");
const profile_mod = @import("release_adapter_profile_endorsement");
const manifest_input_mod = @import("release_adapter_profile_predecessor_manifest_input");
const predecessor_mod = @import("release_adapter_profile_predecessor_authority");
const runner = @import("release_adapter_candidate_upgrade_runner");
const runner_workspace = @import("release_adapter_candidate_upgrade_workspace");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const zig_toolchain = @import("release_adapter_zig_toolchain_authority");
const deadline_mod = @import("release_adapter_deadline");
const pre_publish_workspace = @import("release_adapter_pre_publish_workspace");

pub const Inputs = struct {
    context: context_mod.Context,
    environment: profile_mod.Environment,
    profile: *const profile_mod.Owner,
    manifest_input: *const manifest_input_mod.ProfileManifestInput,
    predecessor_workspace: *pre_publish_workspace.Workspace,
    cli: predecessor_mod.Cli,
    token: []const u8,
    response: []u8,
    candidate: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    candidate_paths: candidate_product.Paths,
    signed_cli_ssh: [:0]const u8,
    source: *const source_tree.SourceTreeAuthority,
    workspace: *runner_workspace.Workspace,
    toolchain: *const zig_toolchain.ZigToolchainAuthority,
    source_directory_fd: c.fd_t,
};

pub const TimingDiagnostic = struct {
    success: bool = false,
    predecessor_auth_ns: u64 = 0,
    signed_one_ns: u64 = 0,
    signed_near_max_ns: u64 = 0,
    runner_phase_ns: u64 = 0,
    profile_phase_ns: u64 = 0,
};

pub const ProfileUpgradeExecution = struct {
    owner: ?*@This() = null,
    deadline: deadline_mod.Deadline = .{},
    predecessor: predecessor_mod.AuthenticatedPredecessor = .{},
    execution: runner.Execution = .{},
    timing: TimingDiagnostic = .{},

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.deadline.isPristineForComposition() and
            self.predecessor.isPristineForComposition() and self.execution.isPristineForComposition() and
            std.meta.eql(self.timing, TimingDiagnostic{});
    }

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        return self.owner == self and self.deadline.owner == &self.deadline and
            self.predecessor.owner == &self.predecessor and self.execution.ownsSuccessfulOutputs() and self.timing.success;
    }

    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        return cleanupOwned(self);
    }
};

pub fn timingForTest(predecessor_ns: u64, runner_timing: runner.TimingDiagnostic, phase_started: i128, phase_finished: i128) !TimingDiagnostic {
    if (predecessor_ns == 0 or !runner_timing.success or runner_timing.signed_one_ns == 0 or
        runner_timing.signed_near_max_ns == 0 or runner_timing.phase_ns == 0 or
        phase_started < 0 or phase_finished <= phase_started) return error.InvalidTiming;
    const child_sum = std.math.add(u64, runner_timing.signed_one_ns, runner_timing.signed_near_max_ns) catch return error.InvalidTiming;
    if (runner_timing.phase_ns < child_sum) return error.InvalidTiming;
    const profile_delta = std.math.sub(i128, phase_finished, phase_started) catch return error.InvalidTiming;
    const profile_ns = std.math.cast(u64, profile_delta) orelse return error.InvalidTiming;
    const nested_sum = std.math.add(u64, predecessor_ns, runner_timing.phase_ns) catch return error.InvalidTiming;
    if (profile_ns < nested_sum) return error.InvalidTiming;
    return .{
        .success = true,
        .predecessor_auth_ns = predecessor_ns,
        .signed_one_ns = runner_timing.signed_one_ns,
        .signed_near_max_ns = runner_timing.signed_near_max_ns,
        .runner_phase_ns = runner_timing.phase_ns,
        .profile_phase_ns = profile_ns,
    };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, budget_ns: i128, result: *ProfileUpgradeExecution) !void {
    var operations = Product{ .io = io, .allocator = allocator, .inputs = inputs };
    var clock = RealClock{};
    return runOwned(&operations, &clock, budget_ns, result);
}

pub fn runWith(operations: anytype, clock: anytype, budget_ns: i128, result: *ProfileUpgradeExecution) !void {
    if (!builtin.is_test) @compileError("runWith is test-only");
    return runOwned(operations, clock, budget_ns, result);
}

fn runOwned(operations: anytype, clock: anytype, budget_ns: i128, result: *ProfileUpgradeExecution) !void {
    try operations.preflight(result);
    try operations.startDeadline(budget_ns, &result.deadline);
    result.owner = result;
    const phase_started = clock.now() catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    const predecessor_started = phase_started;
    operations.authenticatePredecessor(&result.deadline, &result.predecessor) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    const predecessor_finished = clock.now() catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.revalidatePredecessor(&result.deadline, &result.predecessor) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.runSigned(&result.deadline, &result.predecessor, &result.execution) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.revalidateFinal(&result.deadline, &result.predecessor, &result.execution) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.validateSuccess(&result.predecessor, &result.execution) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    operations.finalDeadline(&result.deadline) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    const phase_finished = clock.now() catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
    const predecessor_ns = std.math.cast(u64, predecessor_finished - predecessor_started) orelse {
        abortWith(operations, result) catch return error.CleanupFailed;
        return error.InvalidTiming;
    };
    result.timing = timingForTest(predecessor_ns, result.execution.timing, phase_started, phase_finished) catch |err| {
        abortWith(operations, result) catch return error.CleanupFailed;
        return err;
    };
}

const Product = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,

    fn preflight(self: *@This(), result: *const ProfileUpgradeExecution) !void {
        return validateInputs(self.inputs, result);
    }
    fn startDeadline(_: *@This(), budget_ns: i128, deadline: *deadline_mod.Deadline) !void {
        return deadline_mod.start(budget_ns, deadline);
    }
    fn authenticatePredecessor(self: *@This(), deadline: *deadline_mod.Deadline, result: *predecessor_mod.AuthenticatedPredecessor) !void {
        return predecessor_mod.authenticateUntil(self.io, self.allocator, self.inputs.context, self.inputs.environment, self.inputs.profile, self.inputs.manifest_input, self.inputs.predecessor_workspace, self.inputs.cli, self.inputs.token, self.inputs.response, deadline, result);
    }
    fn revalidatePredecessor(self: *@This(), deadline: *deadline_mod.Deadline, result: *const predecessor_mod.AuthenticatedPredecessor) !void {
        _ = try result.revalidate(self.allocator, self.inputs.context, self.inputs.environment, self.inputs.profile, self.inputs.manifest_input, deadline);
    }
    fn runSigned(self: *@This(), deadline: *deadline_mod.Deadline, predecessor: *predecessor_mod.AuthenticatedPredecessor, result: *runner.Execution) !void {
        const manifest_view = self.inputs.manifest_input.view() orelse return error.AuthorityChanged;
        return runner.runBorrowingDeadline(self.io, self.allocator, .{
            .context = self.inputs.context,
            .candidate = self.inputs.candidate,
            .files = self.inputs.files,
            .product = self.inputs.product,
            .candidate_paths = self.inputs.candidate_paths,
            .signed_cli_ssh = self.inputs.signed_cli_ssh,
            .source = self.inputs.source,
            .predecessor = &predecessor.identity,
            .authenticated = manifest_view.authenticated,
            .held_manifest = manifest_view.file,
            .assets = &predecessor.assets,
            .workspace = self.inputs.workspace,
            .toolchain = self.inputs.toolchain,
            .source_directory_fd = self.inputs.source_directory_fd,
        }, deadline, result);
    }
    fn revalidateFinal(self: *@This(), deadline: *deadline_mod.Deadline, predecessor: *const predecessor_mod.AuthenticatedPredecessor, execution: *const runner.Execution) !void {
        _ = try predecessor.revalidate(self.allocator, self.inputs.context, self.inputs.environment, self.inputs.profile, self.inputs.manifest_input, deadline);
        _ = try self.inputs.candidate.revalidate(self.inputs.context, self.inputs.files, self.inputs.product, self.inputs.candidate_paths, self.inputs.source);
        const retained_paths = try self.inputs.workspace.value();
        _ = try execution.evidence.revalidate(retained_paths.evidence);
    }
    fn finalDeadline(_: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
    }
    fn validateSuccess(_: *@This(), predecessor: *const predecessor_mod.AuthenticatedPredecessor, execution: *const runner.Execution) !void {
        if (predecessor.owner != predecessor or !execution.ownsSuccessfulOutputs()) return error.InvalidOwner;
    }
    fn cleanupExecution(_: *@This(), execution: *runner.Execution) !void {
        if (execution.ownsSuccessfulOutputs()) return execution.cleanup();
        if (execution.needsCleanup()) return runner.retryCleanup(execution);
    }
    fn cleanupPredecessor(_: *@This(), predecessor: *predecessor_mod.AuthenticatedPredecessor) !void {
        if (predecessor.owner == predecessor) return predecessor.retryCleanup();
    }
    fn cleanupDeadline(_: *@This(), deadline: *deadline_mod.Deadline) !void {
        if (deadline.owner == deadline) return deadline.deinit();
    }
};

pub fn retryCleanup(result: *ProfileUpgradeExecution) !void {
    if (result.owner != result or result.ownsSuccessfulOutputs()) return error.InvalidOwner;
    return cleanupOwned(result);
}

pub fn retryCleanupWith(operations: anytype, result: *ProfileUpgradeExecution) !void {
    if (!builtin.is_test) @compileError("retryCleanupWith is test-only");
    if (result.owner != result or result.ownsSuccessfulOutputs()) return error.InvalidOwner;
    return cleanupWith(operations, result);
}

fn validateInputs(inputs: Inputs, result: *const ProfileUpgradeExecution) !void {
    if (!result.isPristineForComposition() or inputs.source_directory_fd < 0 or
        inputs.predecessor_workspace == &inputs.workspace.root) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    const borrowed = [_][]const u8{
        std.mem.asBytes(inputs.profile),               std.mem.asBytes(inputs.manifest_input),
        std.mem.asBytes(inputs.predecessor_workspace), std.mem.asBytes(inputs.cli.pinned),
        std.mem.asBytes(inputs.candidate),             std.mem.asBytes(inputs.files),
        std.mem.asBytes(inputs.product),               std.mem.asBytes(inputs.source),
        std.mem.asBytes(inputs.workspace),             std.mem.asBytes(inputs.toolchain),
        inputs.cli.path,                               inputs.token,
        inputs.context.repository.owner,               inputs.context.repository.name,
        inputs.context.tag,                            inputs.context.source_commit,
        inputs.context.build.workflow_ref,             inputs.candidate_paths.dmg,
        inputs.candidate_paths.frozen_executable,      inputs.candidate_paths.dmg_work,
        inputs.signed_cli_ssh,
    };
    if (overlaps(result_bytes, inputs.response)) return error.InvalidOwner;
    for (borrowed) |other| {
        if (overlaps(result_bytes, other) or overlaps(inputs.response, other)) return error.InvalidOwner;
    }
    if (overlaps(std.mem.asBytes(inputs.predecessor_workspace), std.mem.asBytes(inputs.workspace))) return error.InvalidOwner;
    const environment_pointer = @intFromPtr(inputs.environment.context);
    inline for (.{ result_bytes, inputs.response, std.mem.asBytes(inputs.predecessor_workspace), std.mem.asBytes(inputs.workspace) }) |storage| {
        const start = @intFromPtr(storage.ptr);
        const end = std.math.add(usize, start, storage.len) catch return error.InvalidOwner;
        if (environment_pointer >= start and environment_pointer < end) return error.InvalidOwner;
    }
    try inputs.predecessor_workspace.validate();
    _ = try inputs.workspace.value();
    const predecessor_path = inputs.predecessor_workspace.path_storage[0..inputs.predecessor_workspace.path_len];
    const upgrade_path = inputs.workspace.root.path_storage[0..inputs.workspace.root.path_len];
    if (pathContains(predecessor_path, upgrade_path) or pathContains(upgrade_path, predecessor_path)) return error.InvalidOwner;
}

fn cleanupOwned(result: *ProfileUpgradeExecution) !void {
    var failed = false;
    if (result.execution.ownsSuccessfulOutputs()) {
        result.execution.cleanup() catch {
            failed = true;
        };
    } else if (result.execution.needsCleanup()) {
        runner.retryCleanup(&result.execution) catch {
            failed = true;
        };
    }
    if (result.predecessor.owner == &result.predecessor) result.predecessor.retryCleanup() catch {
        failed = true;
    };
    if (result.deadline.owner == &result.deadline) result.deadline.deinit() catch {
        failed = true;
    };
    result.timing = .{};
    if (failed or !result.execution.isPristineForComposition() or !result.predecessor.isPristineForComposition() or
        !result.deadline.isPristineForComposition())
    {
        result.owner = result;
        return error.CleanupFailed;
    }
    result.* = .{};
}

fn abortWith(operations: anytype, result: *ProfileUpgradeExecution) !void {
    return cleanupWith(operations, result);
}

fn cleanupWith(operations: anytype, result: *ProfileUpgradeExecution) !void {
    var failed = false;
    operations.cleanupExecution(&result.execution) catch {
        failed = true;
    };
    operations.cleanupPredecessor(&result.predecessor) catch {
        failed = true;
    };
    operations.cleanupDeadline(&result.deadline) catch {
        failed = true;
    };
    result.timing = .{};
    if (failed or !result.execution.isPristineForComposition() or !result.predecessor.isPristineForComposition() or
        !result.deadline.isPristineForComposition())
    {
        result.owner = result;
        return error.CleanupFailed;
    }
    result.* = .{};
}

const RealClock = struct {
    fn now(_: *@This()) !i128 {
        var ts: c.timespec = undefined;
        if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
};

fn pathContains(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0 or child.len == 0) return false;
    if (std.mem.eql(u8, parent, child)) return true;
    return child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/';
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
