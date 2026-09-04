//! Closed transaction for one candidate release from prerequisite through publication.
//!
//! The concrete production owner retains every typed authority. This lifecycle fixes the only
//! legal phase order and preserves the whole graph once draft mutation makes automatic retry
//! unsafe. It borrows one deadline and never creates or closes it.

pub const AuditStage = enum { none, prerequisite, baseline, publication };

pub const Release = struct {
    owner: ?*Release = null,
    prerequisite_attempted: bool = false,
    baseline_attempted: bool = false,
    publication_attempted: bool = false,
    successful: bool = false,
    cleanup_required: bool = false,
    audit_required: bool = false,
    audit_stage: AuditStage = .none,

    pub fn ownsCompleteRelease(self: *const @This()) bool {
        return self.owner == self and self.successful and !self.cleanup_required and
            !self.audit_required and self.audit_stage == .none and self.allAttempted();
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and self.cleanup_required and
            !self.audit_required and self.audit_stage == .none and self.anyAttempted();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and !self.successful and !self.cleanup_required and
            self.audit_required and self.audit_stage != .none and self.prerequisite_attempted;
    }

    pub fn auditStage(self: *const @This()) AuditStage {
        return if (self.needsAudit()) self.audit_stage else .none;
    }

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and !self.anyAttempted() and !self.successful and
            !self.cleanup_required and !self.audit_required and self.audit_stage == .none;
    }

    fn anyAttempted(self: *const @This()) bool {
        return self.prerequisite_attempted or self.baseline_attempted or self.publication_attempted;
    }

    fn allAttempted(self: *const @This()) bool {
        return self.prerequisite_attempted and self.baseline_attempted and self.publication_attempted;
    }
};

pub fn executeWith(steps: anytype, deadline: anytype, release: *Release) !void {
    if (!release.pristine()) return error.InvalidOwner;
    steps.validatePreflight(release, deadline) catch |err| {
        release.* = .{};
        return err;
    };
    if (!release.pristine()) {
        release.* = .{};
        return error.InvalidOwner;
    }
    release.owner = release;

    steps.validateAuthority(deadline) catch |err| {
        release.* = .{};
        return err;
    };

    release.prerequisite_attempted = true;
    steps.runPrerequisite(deadline) catch |err| {
        if (steps.prerequisiteNeedsAudit()) return requireAudit(release, .prerequisite);
        if (steps.prerequisiteNeedsCleanup()) {
            release.cleanup_required = true;
            return err;
        }
        if (!steps.prerequisiteIsPristine()) return requireAudit(release, .prerequisite);
        release.* = .{};
        return err;
    };
    // A ready draft now exists. Every later uncertainty must retain the exact graph for audit.
    steps.validateAuthority(deadline) catch return requireAudit(release, .prerequisite);

    release.baseline_attempted = true;
    steps.runBaseline(deadline) catch return requireAudit(release, .baseline);
    steps.validateAuthority(deadline) catch return requireAudit(release, .baseline);

    release.publication_attempted = true;
    steps.runPublication(deadline) catch return requireAudit(release, .publication);
    steps.validateAuthority(deadline) catch return requireAudit(release, .publication);

    release.successful = true;
}

pub fn cleanupWith(steps: anytype, release: *Release) !void {
    if (!release.ownsCompleteRelease()) return error.InvalidOwner;
    release.successful = false;
    release.cleanup_required = true;
    if (!unwind(steps, release)) return error.CleanupFailed;
    release.* = .{};
}

pub fn retryCleanupWith(steps: anytype, release: *Release) !void {
    if (!release.needsCleanup()) return error.InvalidOwner;
    if (!unwind(steps, release)) return error.CleanupFailed;
    release.* = .{};
}

fn requireAudit(release: *Release, stage: AuditStage) anyerror {
    release.successful = false;
    release.cleanup_required = false;
    release.audit_required = true;
    release.audit_stage = stage;
    return error.AuditRequired;
}

fn unwind(steps: anytype, release: *Release) bool {
    if (release.publication_attempted and !cleanOne(steps, release, .publication)) return false;
    if (release.baseline_attempted and !cleanOne(steps, release, .baseline)) return false;
    if (release.prerequisite_attempted and !cleanOne(steps, release, .prerequisite)) return false;
    return !release.anyAttempted();
}

const Owner = enum { prerequisite, baseline, publication };

fn cleanOne(steps: anytype, release: *Release, comptime owner: Owner) bool {
    const released = switch (owner) {
        .prerequisite => blk: {
            steps.cleanupPrerequisite() catch break :blk false;
            break :blk true;
        },
        .baseline => blk: {
            steps.cleanupBaseline() catch break :blk false;
            break :blk true;
        },
        .publication => blk: {
            steps.cleanupPublication() catch break :blk false;
            break :blk true;
        },
    };
    if (!released) return false;
    switch (owner) {
        .prerequisite => release.prerequisite_attempted = false,
        .baseline => release.baseline_attempted = false,
        .publication => release.publication_attempted = false,
    }
    return true;
}
