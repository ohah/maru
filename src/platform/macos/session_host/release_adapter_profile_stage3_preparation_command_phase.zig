//! Closed reducer for the fresh-process upgrade-B stage-3 command.

pub const Stage = enum(u8) {
    none,
    preflight,
    profile,
    prerequisite,
    predecessor_workspace,
    manifest_input,
    upgrade_workspace,
    authorities,
    profile_upgrade,
    durable,
    timing,
    retained_close,
};

const first_local = @intFromEnum(Stage.profile);
const last_local = @intFromEnum(Stage.timing);

pub const Transaction = struct {
    owner: ?*Transaction = null,
    audit_required: bool = false,
    cleanup_required: bool = false,
    audit_stage: Stage = .none,
    remote_commit_observed: bool = false,
    durable_retained: bool = false,
    timing_retained: bool = false,
    timing_audit_preserved: bool = false,
    live: [last_local + 1]bool = @splat(false),

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and !self.audit_required and !self.cleanup_required and
            self.audit_stage == .none and !self.remote_commit_observed and !self.durable_retained and
            !self.timing_retained and !self.timing_audit_preserved and !self.anyLive();
    }
    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.audit_required and !self.cleanup_required and
            self.audit_stage != .none and (self.remote_commit_observed or self.durable_retained);
    }
    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and self.cleanup_required and !self.audit_required and self.anyLive();
    }
    pub fn localCleanupComplete(self: *const @This()) bool {
        return self.needsAudit() and !self.anyLive();
    }
    fn anyLive(self: *const @This()) bool {
        for (self.live[first_local..]) |value| if (value) return true;
        return false;
    }
};

pub fn executeWith(steps: anytype, transaction: *Transaction) !void {
    if (!transaction.isPristineForComposition()) return error.InvalidOwner;
    try steps.validatePreflight();
    if (!transaction.isPristineForComposition()) return error.InvalidOwner;
    transaction.owner = transaction;

    transaction.live[@intFromEnum(Stage.profile)] = true;
    steps.bindProfile() catch |err| return settle(steps, transaction, .profile, err, false);
    transaction.live[@intFromEnum(Stage.prerequisite)] = true;
    steps.runPrerequisite() catch |err| {
        const audit = steps.prerequisiteNeedsAudit();
        if (audit) transaction.remote_commit_observed = true;
        return settle(steps, transaction, .prerequisite, err, audit);
    };
    transaction.remote_commit_observed = true;
    transaction.live[@intFromEnum(Stage.predecessor_workspace)] = true;
    steps.preparePredecessorWorkspace() catch |err| return settle(steps, transaction, .predecessor_workspace, err, true);
    transaction.live[@intFromEnum(Stage.manifest_input)] = true;
    steps.authenticateManifest() catch |err| return settle(steps, transaction, .manifest_input, err, true);
    transaction.live[@intFromEnum(Stage.upgrade_workspace)] = true;
    steps.prepareUpgradeWorkspace() catch |err| return settle(steps, transaction, .upgrade_workspace, err, true);
    transaction.live[@intFromEnum(Stage.authorities)] = true;
    steps.bindAuthorities() catch |err| return settle(steps, transaction, .authorities, err, true);
    transaction.live[@intFromEnum(Stage.profile_upgrade)] = true;
    steps.runProfileUpgrade() catch |err| return settle(steps, transaction, .profile_upgrade, err, true);

    transaction.live[@intFromEnum(Stage.durable)] = true;
    steps.prepareDurable() catch |err| {
        if (steps.durableNeedsAudit()) transaction.durable_retained = true;
        return settle(steps, transaction, .durable, err, true);
    };
    transaction.live[@intFromEnum(Stage.durable)] = false;
    transaction.durable_retained = true;
    transaction.live[@intFromEnum(Stage.timing)] = true;
    steps.publishTiming() catch |err| {
        if (steps.timingNeedsAudit()) {
            transaction.live[@intFromEnum(Stage.timing)] = false;
            transaction.timing_audit_preserved = true;
        }
        return settle(steps, transaction, .timing, err, true);
    };
    steps.closeTimingRetaining() catch |err| {
        transaction.live[@intFromEnum(Stage.timing)] = false;
        transaction.timing_audit_preserved = true;
        return settle(steps, transaction, .retained_close, err, true);
    };
    transaction.live[@intFromEnum(Stage.timing)] = false;
    transaction.timing_retained = true;
    if (!unwind(steps, transaction)) return settle(steps, transaction, .retained_close, error.CleanupFailed, true);
    transaction.* = .{};
}

pub fn retryCleanupWith(steps: anytype, transaction: *Transaction) !void {
    if (!transaction.needsCleanup()) return error.InvalidOwner;
    if (!unwind(steps, transaction)) return error.CleanupFailed;
    transaction.* = .{};
}

pub fn retryAuditCleanupWith(steps: anytype, transaction: *Transaction) !void {
    if (!transaction.needsAudit() or !transaction.anyLive()) return error.InvalidOwner;
    if (!unwind(steps, transaction)) return error.CleanupFailed;
}

fn settle(steps: anytype, transaction: *Transaction, stage: Stage, cause: anyerror, audit: bool) anyerror {
    const clean = unwind(steps, transaction);
    if (audit) {
        transaction.audit_required = true;
        transaction.cleanup_required = false;
        transaction.audit_stage = stage;
        return error.AuditRequired;
    }
    if (!clean) {
        transaction.cleanup_required = true;
        return error.CleanupFailed;
    }
    transaction.* = .{};
    return cause;
}

fn unwind(steps: anytype, transaction: *Transaction) bool {
    var clean = true;
    var index: usize = last_local + 1;
    while (index > first_local) {
        index -= 1;
        if (!transaction.live[index]) continue;
        steps.cleanup(@enumFromInt(index)) catch {
            clean = false;
            continue;
        };
        transaction.live[index] = false;
    }
    return clean;
}
