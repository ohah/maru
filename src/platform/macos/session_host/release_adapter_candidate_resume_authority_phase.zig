//! Ordered transaction for rebuilding publication authority after stage 4.

pub const State = enum { pristine, running, ready, audit_required, audit_cleanup_required, ready_cleanup_required, audit_clean };
pub const CleanupDisposition = enum { complete, descriptor_close_failed };

pub const Transaction = struct {
    owner: ?*Transaction = null,
    state: State = .pristine,
    preparation: bool = false,
    aggregate: bool = false,
    current: bool = false,
    draft: bool = false,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.state == .pristine and !self.preparation and !self.aggregate and !self.current and !self.draft;
    }
    pub fn isReady(self: *const @This()) bool {
        return self.owner == self and self.state == .ready and self.preparation and self.aggregate and self.current and self.draft;
    }
    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and (self.state == .audit_required or self.state == .audit_cleanup_required or self.state == .audit_clean);
    }
    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and (self.state == .audit_cleanup_required or self.state == .ready_cleanup_required);
    }
    pub fn auditCleanupComplete(self: *const @This()) bool {
        return self.owner == self and self.state == .audit_clean and !self.preparation and !self.aggregate and !self.current and !self.draft;
    }
};

pub fn executeWith(steps: anytype, transaction: *Transaction) !void {
    if (!transaction.isPristineForComposition()) return error.InvalidState;
    transaction.owner = transaction;
    transaction.state = .running;
    errdefer transaction.state = .audit_required;

    try steps.validatePreflight();
    try steps.openPreparation();
    transaction.preparation = true;
    try steps.fencePreparation(false);
    try steps.openAggregate();
    transaction.aggregate = true;
    try steps.fenceAggregate(false);
    try steps.fencePreparation(false);
    try steps.authenticateCurrent();
    transaction.current = true;
    try steps.adoptDraft();
    transaction.draft = true;
    try steps.fencePreparation(true);
    try steps.fenceAggregate(true);
    transaction.state = .ready;
}

pub fn settleFailureWith(steps: anytype, transaction: *Transaction) !CleanupDisposition {
    if (transaction.owner != transaction or transaction.state != .audit_required) return error.InvalidState;
    transaction.state = .audit_cleanup_required;
    return cleanupWith(steps, transaction, .audit_clean);
}

pub fn retryCleanupWith(steps: anytype, transaction: *Transaction) !CleanupDisposition {
    if (transaction.owner != transaction or transaction.state != .audit_cleanup_required) return error.InvalidState;
    return cleanupWith(steps, transaction, .audit_clean);
}

pub fn cleanupReadyWith(steps: anytype, transaction: *Transaction) !CleanupDisposition {
    if (!transaction.isReady()) return error.InvalidState;
    transaction.state = .ready_cleanup_required;
    const disposition = try cleanupWith(steps, transaction, .pristine);
    transaction.* = .{};
    return disposition;
}

pub fn retryReadyCleanupWith(steps: anytype, transaction: *Transaction) !CleanupDisposition {
    if (transaction.owner != transaction or transaction.state != .ready_cleanup_required) return error.InvalidState;
    const disposition = try cleanupWith(steps, transaction, .pristine);
    transaction.* = .{};
    return disposition;
}

fn cleanupWith(steps: anytype, transaction: *Transaction, terminal: State) !CleanupDisposition {
    var disposition: CleanupDisposition = .complete;
    if (transaction.draft) {
        if (try steps.cleanupDraft() == .descriptor_close_failed) disposition = .descriptor_close_failed;
        transaction.draft = false;
    }
    if (transaction.current) {
        if (try steps.cleanupCurrent() == .descriptor_close_failed) disposition = .descriptor_close_failed;
        transaction.current = false;
    }
    if (transaction.aggregate) {
        const result = if (terminal == .audit_clean)
            try steps.cleanupAggregateAudit()
        else
            try steps.cleanupAggregateReady();
        if (result == .descriptor_close_failed) disposition = .descriptor_close_failed;
        transaction.aggregate = false;
    }
    if (transaction.preparation) {
        const result = if (terminal == .audit_clean)
            try steps.cleanupPreparationAudit()
        else
            try steps.cleanupPreparationReady();
        if (result == .descriptor_close_failed) disposition = .descriptor_close_failed;
        transaction.preparation = false;
    }
    transaction.state = terminal;
    return disposition;
}
