//! Final-address owner for the provisioned Notification Center product transaction.
//!
//! Attempts are recorded before delegation because a child may create an OS row or a private
//! leaf and then report failure. Cleanup therefore follows ownership, not return values.

const phase = @import("release_adapter_notification_phase");

pub const Execution = struct {
    owner: ?*Execution = null,
    authorities_bound: bool = false,
    gui_zero_attempted: bool = false,
    gui_live_then_quit_attempted: bool = false,
    evidence_attempted: bool = false,
    successful: bool = false,

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        return self.owner == self and self.authorities_bound and !self.gui_zero_attempted and
            !self.gui_live_then_quit_attempted and self.evidence_attempted and self.successful;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and
            (self.gui_zero_attempted or self.gui_live_then_quit_attempted or self.evidence_attempted);
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and !self.authorities_bound and !self.gui_zero_attempted and
            !self.gui_live_then_quit_attempted and !self.evidence_attempted and !self.successful;
    }
};

pub fn executeWith(steps: anytype, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    execution.owner = execution;
    steps.bindAuthorities() catch |err| {
        execution.* = .{};
        return err;
    };
    execution.authorities_bound = true;
    var adapter = Adapter(@TypeOf(steps)){ .steps = steps, .execution = execution };
    phase.runWith(&adapter) catch |err| {
        if (err == error.CleanupFailed or execution.needsCleanup()) return error.CleanupFailed;
        execution.* = .{};
        return err;
    };
    execution.successful = true;
}

pub fn retryCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!execution.needsCleanup()) return error.InvalidOwner;
    var adapter = Adapter(@TypeOf(steps)){ .steps = steps, .execution = execution };
    try adapter.cleanupAttempted();
    execution.* = .{};
}

fn Adapter(comptime Steps: type) type {
    return struct {
        const StepType = switch (@typeInfo(Steps)) {
            .pointer => |pointer| pointer.child,
            else => Steps,
        };
        const StartReturn = @typeInfo(@TypeOf(StepType.startDeadline)).@"fn".return_type.?;
        const Deadline = @typeInfo(StartReturn).error_union.payload;

        steps: Steps,
        execution: *Execution,

        pub fn startDeadline(self: *@This()) !Deadline {
            return try self.steps.startDeadline();
        }
        pub fn validateInitialAuthorities(self: *@This(), deadline: anytype) !void {
            try self.steps.validateInitialAuthorities(deadline);
        }
        pub fn runGuiZero(self: *@This(), deadline: anytype) !void {
            self.execution.gui_zero_attempted = true;
            try self.steps.runGuiZero(deadline);
        }
        pub fn validateAfterGuiZero(self: *@This(), deadline: anytype) !void {
            try self.steps.validateAfterGuiZero(deadline);
        }
        pub fn runGuiLiveThenQuit(self: *@This(), deadline: anytype) !void {
            self.execution.gui_live_then_quit_attempted = true;
            try self.steps.runGuiLiveThenQuit(deadline);
        }
        pub fn validateAfterGuiLiveThenQuit(self: *@This(), deadline: anytype) !void {
            try self.steps.validateAfterGuiLiveThenQuit(deadline);
        }
        pub fn cleanupNotifications(self: *@This(), deadline: anytype) !void {
            try self.steps.cleanupNotifications(deadline);
            self.execution.gui_live_then_quit_attempted = false;
            self.execution.gui_zero_attempted = false;
        }
        pub fn validateAfterCleanup(self: *@This(), deadline: anytype) !void {
            try self.steps.validateAfterCleanup(deadline);
        }
        pub fn publishEvidence(self: *@This(), deadline: anytype) !void {
            self.execution.evidence_attempted = true;
            try self.steps.publishEvidence(deadline);
        }
        pub fn validateFinalAuthorities(self: *@This(), deadline: anytype) !void {
            try self.steps.validateFinalAuthorities(deadline);
        }
        pub fn validateFinalDeadline(self: *@This(), deadline: anytype) !void {
            try self.steps.validateFinalDeadline(deadline);
        }

        pub fn cleanupAttempted(self: *@This()) !void {
            var clean = true;
            if (self.execution.evidence_attempted) {
                self.steps.cleanupEvidence() catch {
                    clean = false;
                };
                if (clean) self.execution.evidence_attempted = false;
            }
            var live_clean = true;
            if (self.execution.gui_live_then_quit_attempted) {
                self.steps.cleanupGuiLiveThenQuit() catch {
                    clean = false;
                    live_clean = false;
                };
                if (live_clean) self.execution.gui_live_then_quit_attempted = false;
            }
            var zero_clean = true;
            if (self.execution.gui_zero_attempted) {
                self.steps.cleanupGuiZero() catch {
                    clean = false;
                    zero_clean = false;
                };
                if (zero_clean) self.execution.gui_zero_attempted = false;
            }
            if (!clean) return error.CleanupFailed;
        }
    };
}
