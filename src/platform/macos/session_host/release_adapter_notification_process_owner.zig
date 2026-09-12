//! Single ownership state for one Notification Center app/helper process composition.
//!
//! A child can create its externally visible object and fail before returning. Attempts are
//! therefore recorded before delegation, and cleanup retains only the authorities that failed so
//! a retry cannot repeat a successful destructive action.

pub const Execution = struct {
    owner: ?*Execution = null,
    root_attempted: bool = false,
    app_attempted: bool = false,
    helper_attempted: bool = false,
    request_attempted: bool = false,
    receipt_attempted: bool = false,
    successful: bool = false,

    pub fn ownsReceipt(self: *const @This()) bool {
        return self.owner == self and self.successful and self.receipt_attempted and
            !self.root_attempted and !self.app_attempted and !self.helper_attempted and
            !self.request_attempted;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and (self.root_attempted or
            self.app_attempted or self.helper_attempted or self.request_attempted or
            self.receipt_attempted);
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and !self.root_attempted and !self.app_attempted and
            !self.helper_attempted and !self.request_attempted and !self.receipt_attempted and
            !self.successful;
    }
};

pub fn executeWith(steps: anytype, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    execution.owner = execution;
    steps.bind() catch |err| {
        execution.* = .{};
        return err;
    };
    const deadline = steps.startDeadline() catch |err| {
        execution.* = .{};
        return err;
    };

    execution.root_attempted = true;
    steps.createRoot(deadline) catch |err| return fail(steps, execution, err);
    execution.app_attempted = true;
    execution.request_attempted = true;
    steps.launchApp(deadline) catch |err| return fail(steps, execution, err);
    execution.helper_attempted = true;
    const click = steps.runHelper(deadline) catch |err| return fail(steps, execution, err);
    const app_receipt = steps.collectAppReceipt(deadline) catch |err| return fail(steps, execution, err);
    const continuity_receipt = steps.collectContinuityReceipt(deadline) catch |err| return fail(steps, execution, err);
    steps.publishReceipt(deadline, click, app_receipt, continuity_receipt) catch |err| return fail(steps, execution, err);
    // The exclusive publisher owns rollback until it returns success. Recording earlier would
    // authorize cleanup of a pre-existing destination after DestinationExists.
    execution.receipt_attempted = true;

    cleanupEphemeral(steps, execution) catch return error.CleanupFailed;
    execution.successful = true;
}

pub fn retryCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!execution.needsCleanup()) return error.InvalidOwner;
    try cleanupAll(steps, execution);
    execution.* = .{};
}

fn fail(steps: anytype, execution: *Execution, original: anyerror) anyerror {
    cleanupAll(steps, execution) catch return error.CleanupFailed;
    execution.* = .{};
    return original;
}

fn cleanupAll(steps: anytype, execution: *Execution) !void {
    var clean = true;
    if (execution.receipt_attempted) {
        var this_clean = true;
        steps.cleanupReceipt() catch {
            clean = false;
            this_clean = false;
        };
        if (this_clean) execution.receipt_attempted = false;
    }
    cleanupEphemeralInternal(steps, execution, &clean);
    if (!clean) return error.CleanupFailed;
}

fn cleanupEphemeral(steps: anytype, execution: *Execution) !void {
    var clean = true;
    cleanupEphemeralInternal(steps, execution, &clean);
    if (!clean) return error.CleanupFailed;
}

fn cleanupEphemeralInternal(steps: anytype, execution: *Execution, clean: *bool) void {
    if (execution.request_attempted) {
        var this_clean = true;
        steps.cleanupRequest() catch {
            clean.* = false;
            this_clean = false;
        };
        if (this_clean) execution.request_attempted = false;
    }
    if (execution.helper_attempted) {
        var this_clean = true;
        steps.cleanupHelper() catch {
            clean.* = false;
            this_clean = false;
        };
        if (this_clean) execution.helper_attempted = false;
    }
    if (execution.app_attempted) {
        var this_clean = true;
        steps.cleanupApp() catch {
            clean.* = false;
            this_clean = false;
        };
        if (this_clean) execution.app_attempted = false;
    }
    if (execution.root_attempted) {
        var this_clean = true;
        steps.cleanupRoot() catch {
            clean.* = false;
            this_clean = false;
        };
        if (this_clean) execution.root_attempted = false;
    }
}
