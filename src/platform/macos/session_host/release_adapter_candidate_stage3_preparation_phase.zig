//! Closed reducer for candidate stage-3 preparation through its durable commit point.

pub const Stage = enum { none, prerequisite, baseline, manifest, promote, fence, retained_close, local_cleanup };

pub const Transaction = struct {
    owner: ?*Transaction = null,
    audit_required: bool = false,
    cleanup_required: bool = false,
    audit_stage: Stage = .none,
    retained: bool = false,
    prerequisite_live: bool = false,
    baseline_live: bool = false,
    manifest_live: bool = false,
    durable_live: bool = false,
    deadline_live: bool = false,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and !self.audit_required and !self.cleanup_required and self.audit_stage == .none and
            !self.retained and !self.anyLocalLive();
    }
    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and self.cleanup_required and !self.audit_required and self.audit_stage == .none and
            self.anyLocalLive();
    }
    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.audit_required and !self.cleanup_required and self.audit_stage != .none;
    }
    pub fn auditStage(self: *const @This()) Stage {
        return if (self.needsAudit()) self.audit_stage else .none;
    }
    pub fn retainedCommit(self: *const @This()) bool {
        return self.needsAudit() and self.retained;
    }
    pub fn localCleanupComplete(self: *const @This()) bool {
        return self.needsAudit() and !self.anyLocalLive();
    }
    fn anyLocalLive(self: *const @This()) bool {
        return self.prerequisite_live or self.baseline_live or self.manifest_live or self.durable_live or self.deadline_live;
    }
};

pub fn executeWith(steps: anytype, deadline: anytype, transaction: *Transaction) !void {
    if (!transaction.isPristineForComposition()) return error.InvalidOwner;
    steps.validatePreflight(transaction, deadline) catch |err| {
        steps.cleanupDeadline() catch {
            transaction.* = .{ .owner = transaction, .cleanup_required = true, .deadline_live = true };
            return error.CleanupFailed;
        };
        transaction.* = .{};
        return err;
    };
    if (!transaction.isPristineForComposition()) {
        steps.cleanupDeadline() catch {
            transaction.* = .{ .owner = transaction, .cleanup_required = true, .deadline_live = true };
            return error.CleanupFailed;
        };
        transaction.* = .{};
        return error.InvalidOwner;
    }
    transaction.owner = transaction;
    transaction.deadline_live = true;

    steps.validateAuthority(deadline) catch |err| {
        if (!unwind(steps, transaction)) {
            transaction.cleanup_required = true;
            return error.CleanupFailed;
        }
        transaction.* = .{};
        return err;
    };
    transaction.prerequisite_live = true;
    steps.runPrerequisite(deadline) catch |err| {
        if (steps.prerequisiteNeedsAudit()) return requireAudit(transaction, .prerequisite);
        if (!unwind(steps, transaction)) {
            transaction.cleanup_required = true;
            return error.CleanupFailed;
        }
        transaction.* = .{};
        return err;
    };
    steps.validateAuthority(deadline) catch return requireAudit(transaction, .prerequisite);

    transaction.baseline_live = true;
    steps.runBaseline(deadline) catch return requireAudit(transaction, .baseline);
    steps.validateAuthority(deadline) catch return requireAudit(transaction, .baseline);

    transaction.manifest_live = true;
    steps.authorManifest(deadline) catch return requireAudit(transaction, .manifest);
    steps.validateAuthority(deadline) catch return requireAudit(transaction, .manifest);

    transaction.durable_live = true;
    steps.promoteDurable(deadline) catch return requireAudit(transaction, .promote);
    steps.validateAuthority(deadline) catch return requireAudit(transaction, .promote);
    steps.fenceDurable(deadline) catch return requireAudit(transaction, .fence);
    steps.validateAuthority(deadline) catch return requireAudit(transaction, .fence);
    steps.closeRetaining(deadline) catch {
        if (steps.durableRetained()) {
            transaction.retained = true;
            transaction.durable_live = false;
        }
        return requireAudit(transaction, .retained_close);
    };
    transaction.retained = true;
    transaction.durable_live = false;
    steps.validateAuthority(deadline) catch return requireAudit(transaction, .retained_close);

    if (!unwind(steps, transaction)) return requireAudit(transaction, .local_cleanup);
    transaction.* = .{};
}

pub fn retryCleanupWith(steps: anytype, transaction: *Transaction) !void {
    if (!transaction.needsCleanup()) return error.InvalidOwner;
    if (!unwind(steps, transaction)) return error.CleanupFailed;
    transaction.* = .{};
}

pub fn retryAuditCleanupWith(steps: anytype, transaction: *Transaction) !void {
    if (!transaction.needsAudit() or !transaction.anyLocalLive()) return error.InvalidOwner;
    if (!unwind(steps, transaction)) return error.CleanupFailed;
}

fn requireAudit(transaction: *Transaction, stage: Stage) anyerror {
    transaction.audit_required = true;
    transaction.cleanup_required = false;
    transaction.audit_stage = stage;
    return error.AuditRequired;
}

fn unwind(steps: anytype, transaction: *Transaction) bool {
    if (transaction.durable_live) {
        steps.cleanupDurable() catch return false;
        transaction.durable_live = false;
    }
    if (transaction.manifest_live) {
        steps.cleanupManifest() catch return false;
        transaction.manifest_live = false;
    }
    if (transaction.baseline_live) {
        steps.cleanupBaseline() catch return false;
        transaction.baseline_live = false;
    }
    if (transaction.prerequisite_live) {
        steps.cleanupPrerequisite() catch return false;
        transaction.prerequisite_live = false;
    }
    if (transaction.deadline_live) {
        steps.cleanupDeadline() catch return false;
        transaction.deadline_live = false;
    }
    return true;
}
