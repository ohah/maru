//! Closed reducer for upgrade-B manifest authoring and durable preparation.

pub const Stage = enum { none, profile, manifest, promote, fence, retained_close, local_cleanup };

pub const Transaction = struct {
    owner: ?*Transaction = null,
    audit_required: bool = false,
    cleanup_required: bool = false,
    audit_stage: Stage = .none,
    retained: bool = false,
    manifest_live: bool = false,
    durable_live: bool = false,
    deadline_live: bool = false,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and !self.audit_required and !self.cleanup_required and
            self.audit_stage == .none and !self.retained and !self.anyLocalLive();
    }
    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and self.cleanup_required and !self.audit_required and
            self.audit_stage == .none and self.anyLocalLive();
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
        return self.manifest_live or self.durable_live or self.deadline_live;
    }
};

pub fn executeWith(steps: anytype, deadline: anytype, transaction: *Transaction) !void {
    if (!transaction.isPristineForComposition()) return error.InvalidOwner;
    steps.validatePreflight(transaction, deadline) catch |err| {
        steps.cleanupDeadline(deadline) catch {
            transaction.* = .{ .owner = transaction, .cleanup_required = true, .deadline_live = true };
            return error.CleanupFailed;
        };
        transaction.* = .{};
        return err;
    };
    transaction.* = .{ .owner = transaction, .deadline_live = true };

    steps.validateProfile(deadline) catch |err| {
        if (!unwind(steps, deadline, transaction)) {
            transaction.cleanup_required = true;
            return error.CleanupFailed;
        }
        transaction.* = .{};
        return err;
    };
    transaction.manifest_live = true;
    steps.authorManifest(deadline) catch return requireAudit(transaction, .manifest);
    steps.validateProfile(deadline) catch return requireAudit(transaction, .manifest);

    transaction.durable_live = true;
    steps.promoteDurable(deadline) catch return requireAudit(transaction, .promote);
    steps.validateProfile(deadline) catch return requireAudit(transaction, .promote);
    steps.fenceDurable(deadline) catch return requireAudit(transaction, .fence);
    steps.validateProfile(deadline) catch return requireAudit(transaction, .fence);
    steps.closeRetaining(deadline) catch {
        if (steps.durableRetained()) {
            transaction.retained = true;
            transaction.durable_live = false;
        }
        return requireAudit(transaction, .retained_close);
    };
    transaction.retained = true;
    transaction.durable_live = false;
    steps.validateProfile(deadline) catch return requireAudit(transaction, .retained_close);

    if (!unwind(steps, deadline, transaction)) return requireAudit(transaction, .local_cleanup);
    transaction.* = .{};
}

pub fn retryCleanupWith(steps: anytype, deadline: anytype, transaction: *Transaction) !void {
    if (!transaction.needsCleanup()) return error.InvalidOwner;
    if (!unwind(steps, deadline, transaction)) return error.CleanupFailed;
    transaction.* = .{};
}

pub fn retryAuditCleanupWith(steps: anytype, deadline: anytype, transaction: *Transaction) !void {
    if (!transaction.needsAudit() or !transaction.anyLocalLive()) return error.InvalidOwner;
    if (!unwind(steps, deadline, transaction)) return error.CleanupFailed;
}

fn requireAudit(transaction: *Transaction, stage: Stage) anyerror {
    transaction.audit_required = true;
    transaction.cleanup_required = false;
    transaction.audit_stage = stage;
    return error.AuditRequired;
}

fn unwind(steps: anytype, deadline: anytype, transaction: *Transaction) bool {
    var complete = true;
    if (transaction.durable_live) {
        steps.cleanupDurable() catch {
            complete = false;
        };
        if (complete) transaction.durable_live = false;
    }
    if (transaction.manifest_live) {
        steps.cleanupManifest() catch {
            complete = false;
        };
        // A prior durable failure must not stop this independent cleanup. Only this
        // cleanup's own outcome decides whether its owner remains live.
        if (!steps.manifestStillLive()) transaction.manifest_live = false;
    }
    if (transaction.deadline_live) {
        steps.cleanupDeadline(deadline) catch {
            complete = false;
        };
        if (!steps.deadlineStillLive(deadline)) transaction.deadline_live = false;
    }
    return complete and !transaction.anyLocalLive();
}
