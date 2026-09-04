//! Single-owner transaction around baseline workspace, app authority, and signed runner outputs.
//!
//! Leaf adapters retain their semantic and filesystem authority. This layer only fixes ordering,
//! one deadline identity, publication of the complete owner set, and deterministic retry cleanup.

pub const Execution = struct {
    owner: ?*Execution = null,
    deadline_started: bool = false,
    workspace_attempted: bool = false,
    app_attempted: bool = false,
    runner_attempted: bool = false,
    successful: bool = false,

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        return self.owner == self and !self.deadline_started and self.workspace_attempted and
            self.app_attempted and self.runner_attempted and self.successful;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and
            (self.deadline_started or self.workspace_attempted or self.app_attempted or self.runner_attempted);
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and !self.deadline_started and !self.workspace_attempted and
            !self.app_attempted and !self.runner_attempted and !self.successful;
    }
};

pub fn executeWith(steps: anytype, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    steps.validatePreflight(execution) catch |err| return err;
    if (!execution.pristine()) {
        execution.* = .{};
        return error.InvalidOwner;
    }
    execution.owner = execution;

    const deadline = steps.startDeadline() catch |err| {
        execution.* = .{};
        return err;
    };
    execution.deadline_started = true;

    execution.workspace_attempted = true;
    steps.prepareWorkspace(deadline) catch |err| return fail(steps, execution, deadline, err);

    execution.app_attempted = true;
    steps.bindCandidateApp(deadline) catch |err| return fail(steps, execution, deadline, err);

    execution.runner_attempted = true;
    steps.runBaseline(deadline) catch |err| return fail(steps, execution, deadline, err);

    steps.validateFinalCandidate(deadline) catch |err| return fail(steps, execution, deadline, err);
    steps.validateFinalDeadline(deadline) catch |err| return fail(steps, execution, deadline, err);
    steps.cleanupDeadline(deadline) catch {
        if (unwind(steps, execution, deadline)) execution.* = .{};
        return error.CleanupFailed;
    };
    execution.deadline_started = false;
    execution.successful = true;
}

pub fn cleanupWith(steps: anytype, execution: *Execution) !void {
    if (!execution.ownsSuccessfulOutputs()) return error.InvalidOwner;
    execution.successful = false;
    if (!unwindOutputs(steps, execution)) return error.CleanupFailed;
    execution.* = .{};
}

pub fn retryCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!execution.needsCleanup()) return error.InvalidOwner;
    var clean = unwindOutputs(steps, execution);
    if (execution.deadline_started) {
        var released = true;
        steps.retryCleanupDeadline() catch {
            clean = false;
            released = false;
        };
        if (released) execution.deadline_started = false;
    }
    if (!clean or execution.deadline_started or execution.workspace_attempted or
        execution.app_attempted or execution.runner_attempted) return error.CleanupFailed;
    execution.* = .{};
}

fn fail(steps: anytype, execution: *Execution, deadline: anytype, original: anyerror) anyerror {
    if (!unwind(steps, execution, deadline)) return error.CleanupFailed;
    execution.* = .{};
    return original;
}

fn unwind(steps: anytype, execution: *Execution, deadline: anytype) bool {
    var clean = unwindOutputs(steps, execution);
    if (execution.deadline_started) {
        var released = true;
        steps.cleanupDeadline(deadline) catch {
            clean = false;
            released = false;
        };
        if (released) execution.deadline_started = false;
    }
    return clean and !execution.deadline_started and !execution.workspace_attempted and
        !execution.app_attempted and !execution.runner_attempted;
}

fn unwindOutputs(steps: anytype, execution: *Execution) bool {
    var clean = true;
    if (execution.runner_attempted) {
        var released = true;
        steps.cleanupRunner() catch {
            clean = false;
            released = false;
        };
        if (released) execution.runner_attempted = false;
    }
    if (execution.app_attempted) {
        var released = true;
        steps.cleanupApp() catch {
            clean = false;
            released = false;
        };
        if (released) execution.app_attempted = false;
    }
    if (execution.workspace_attempted) {
        var released = true;
        steps.cleanupWorkspace() catch {
            clean = false;
            released = false;
        };
        if (released) execution.workspace_attempted = false;
    }
    return clean and !execution.workspace_attempted and !execution.app_attempted and !execution.runner_attempted;
}
