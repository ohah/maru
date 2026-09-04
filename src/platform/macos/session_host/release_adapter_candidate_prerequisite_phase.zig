//! Closed preparation transaction for the authorities consumed by candidate publication.
//!
//! Leaf adapters retain their GitHub, filesystem, and semantic authority. This lifecycle fixes
//! their order, one borrowed deadline identity, and the draft mutation boundary after which an
//! automatic cleanup or retry could create a second release.

pub const AuditStage = enum { none, draft, files, product, source, identity, compatibility };

pub const Preparation = struct {
    owner: ?*Preparation = null,
    attestation_attempted: bool = false,
    draft_attempted: bool = false,
    files_attempted: bool = false,
    product_attempted: bool = false,
    source_attempted: bool = false,
    identity_attempted: bool = false,
    compatibility_attempted: bool = false,
    successful: bool = false,
    audit_required: bool = false,
    audit_stage: AuditStage = .none,

    pub fn ownsCompletePrerequisites(self: *const @This()) bool {
        return self.owner == self and self.successful and !self.audit_required and
            self.audit_stage == .none and self.allAttempted();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and !self.successful and self.audit_required and
            self.audit_stage != .none and self.draft_attempted;
    }

    pub fn auditStage(self: *const @This()) AuditStage {
        return if (self.needsAudit()) self.audit_stage else .none;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and !self.audit_required and
            self.audit_stage == .none and self.anyAttempted();
    }

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and !self.anyAttempted() and !self.successful and
            !self.audit_required and self.audit_stage == .none;
    }

    fn anyAttempted(self: *const @This()) bool {
        return self.attestation_attempted or self.draft_attempted or self.files_attempted or
            self.product_attempted or self.source_attempted or self.identity_attempted or
            self.compatibility_attempted;
    }

    fn allAttempted(self: *const @This()) bool {
        return self.attestation_attempted and self.draft_attempted and self.files_attempted and
            self.product_attempted and self.source_attempted and self.identity_attempted and
            self.compatibility_attempted;
    }
};

pub fn executeWith(steps: anytype, deadline: anytype, preparation: *Preparation) !void {
    if (!preparation.pristine()) return error.InvalidOwner;
    steps.validatePreflight(preparation, deadline) catch |err| {
        preparation.* = .{};
        return err;
    };
    if (!preparation.pristine()) {
        preparation.* = .{};
        return error.InvalidOwner;
    }
    preparation.owner = preparation;

    steps.validateAuthority(deadline) catch |err| return failLocal(steps, preparation, err);

    preparation.attestation_attempted = true;
    steps.attestCandidate(deadline) catch |err| return failLocal(steps, preparation, err);
    steps.validateAuthority(deadline) catch |err| return failLocal(steps, preparation, err);

    preparation.draft_attempted = true;
    steps.createDraft(deadline) catch |err| {
        if (steps.draftRequiresAudit()) return requireAudit(preparation, .draft);
        preparation.draft_attempted = false;
        return failLocal(steps, preparation, err);
    };
    steps.validateAuthority(deadline) catch return requireAudit(preparation, .draft);

    preparation.files_attempted = true;
    steps.bindFiles(deadline) catch return requireAudit(preparation, .files);
    steps.validateAuthority(deadline) catch return requireAudit(preparation, .files);

    preparation.product_attempted = true;
    steps.observeProduct(deadline) catch return requireAudit(preparation, .product);
    steps.validateAuthority(deadline) catch return requireAudit(preparation, .product);

    preparation.source_attempted = true;
    steps.observeSource(deadline) catch return requireAudit(preparation, .source);
    steps.validateAuthority(deadline) catch return requireAudit(preparation, .source);

    preparation.identity_attempted = true;
    steps.composeIdentity(deadline) catch return requireAudit(preparation, .identity);
    steps.validateAuthority(deadline) catch return requireAudit(preparation, .identity);

    preparation.compatibility_attempted = true;
    steps.probeCompatibility(deadline) catch return requireAudit(preparation, .compatibility);
    steps.validateAuthority(deadline) catch return requireAudit(preparation, .compatibility);

    preparation.successful = true;
}

pub fn cleanupWith(steps: anytype, preparation: *Preparation) !void {
    if (!preparation.ownsCompletePrerequisites()) return error.InvalidOwner;
    preparation.successful = false;
    if (!unwind(steps, preparation)) return error.CleanupFailed;
    preparation.* = .{};
}

pub fn retryCleanupWith(steps: anytype, preparation: *Preparation) !void {
    if (!preparation.needsCleanup()) return error.InvalidOwner;
    if (!unwind(steps, preparation)) return error.CleanupFailed;
    preparation.* = .{};
}

fn failLocal(steps: anytype, preparation: *Preparation, original: anyerror) anyerror {
    if (!unwind(steps, preparation)) return error.CleanupFailed;
    preparation.* = .{};
    return original;
}

fn requireAudit(preparation: *Preparation, stage: AuditStage) anyerror {
    preparation.successful = false;
    preparation.audit_required = true;
    preparation.audit_stage = stage;
    return error.AuditRequired;
}

fn unwind(steps: anytype, preparation: *Preparation) bool {
    var clean = true;
    if (preparation.compatibility_attempted) cleanOne(steps, preparation, .compatibility, &clean);
    if (preparation.identity_attempted) cleanOne(steps, preparation, .identity, &clean);
    if (preparation.source_attempted) cleanOne(steps, preparation, .source, &clean);
    if (preparation.product_attempted) cleanOne(steps, preparation, .product, &clean);
    if (preparation.files_attempted) cleanOne(steps, preparation, .files, &clean);
    if (preparation.draft_attempted) cleanOne(steps, preparation, .draft, &clean);
    if (preparation.attestation_attempted) cleanOne(steps, preparation, .attestation, &clean);
    return clean and !preparation.anyAttempted();
}

const LocalOwner = enum { attestation, draft, files, product, source, identity, compatibility };

fn cleanOne(steps: anytype, preparation: *Preparation, comptime owner: LocalOwner, clean: *bool) void {
    const released = switch (owner) {
        .attestation => blk: {
            steps.cleanupAttestation() catch break :blk false;
            break :blk true;
        },
        .draft => blk: {
            steps.cleanupDraft() catch break :blk false;
            break :blk true;
        },
        .files => blk: {
            steps.cleanupFiles() catch break :blk false;
            break :blk true;
        },
        .product => blk: {
            steps.cleanupProduct() catch break :blk false;
            break :blk true;
        },
        .source => blk: {
            steps.cleanupSource() catch break :blk false;
            break :blk true;
        },
        .identity => blk: {
            steps.cleanupIdentity() catch break :blk false;
            break :blk true;
        },
        .compatibility => blk: {
            steps.cleanupCompatibility() catch break :blk false;
            break :blk true;
        },
    };
    if (!released) {
        clean.* = false;
        return;
    }
    switch (owner) {
        .attestation => preparation.attestation_attempted = false,
        .draft => preparation.draft_attempted = false,
        .files => preparation.files_attempted = false,
        .product => preparation.product_attempted = false,
        .source => preparation.source_attempted = false,
        .identity => preparation.identity_attempted = false,
        .compatibility => preparation.compatibility_attempted = false,
    }
}
