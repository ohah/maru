//! Shared remote publication suffix for fresh and resumed candidate releases.
//!
//! Concrete products retain every filesystem and GitHub capability. This pointer-free owner keeps
//! the irreversible ordering and audit boundary in one place so resume cannot grow a second policy.

const std = @import("std");

pub const AuditStage = enum { none, attachment, publication, post_publish };

pub const Publication = struct {
    owner: ?*Publication = null,
    audit_seal: [32]u8 = @splat(0),
    attachment_attempted: bool = false,
    redownload_attempted: bool = false,
    publication_attempted: bool = false,
    verification_attempted: bool = false,
    successful: bool = false,
    audit_required: bool = false,
    audit_stage: AuditStage = .none,

    pub fn ownsCompletePublication(self: *const @This()) bool {
        return self.owner == self and self.successful and !self.audit_required and self.audit_stage == .none and
            validAuditSeal(self.audit_seal) and self.allAttempted();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and !self.successful and self.audit_required and self.audit_stage != .none and
            validAuditSeal(self.audit_seal) and self.auditShapeIsCanonical();
    }

    pub fn auditStage(self: *const @This()) AuditStage {
        return if (self.needsAudit()) self.audit_stage else .none;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and !self.audit_required and self.audit_stage == .none and
            validAuditSeal(self.audit_seal) and self.anyAttempted();
    }

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and std.mem.allEqual(u8, &self.audit_seal, 0) and !self.anyAttempted() and
            !self.successful and !self.audit_required and self.audit_stage == .none;
    }

    fn runningShapeIsCanonical(self: *const @This()) bool {
        if (self.owner != self or self.successful or self.audit_required or self.audit_stage != .none or
            !validAuditSeal(self.audit_seal)) return false;
        return (!self.redownload_attempted or self.attachment_attempted) and
            (!self.publication_attempted or self.redownload_attempted) and
            (!self.verification_attempted or self.publication_attempted);
    }

    fn auditShapeIsCanonical(self: *const @This()) bool {
        return switch (self.audit_stage) {
            .none => false,
            .attachment => self.attachment_attempted and !self.publication_attempted and !self.verification_attempted,
            .publication => self.attachment_attempted and self.redownload_attempted and self.publication_attempted and !self.verification_attempted,
            .post_publish => self.allAttempted(),
        };
    }

    fn anyAttempted(self: *const @This()) bool {
        return self.attachment_attempted or self.redownload_attempted or self.publication_attempted or self.verification_attempted;
    }

    fn allAttempted(self: *const @This()) bool {
        return self.attachment_attempted and self.redownload_attempted and self.publication_attempted and self.verification_attempted;
    }
};

pub fn executeWith(steps: anytype, deadline: anytype, audit_seal: [32]u8, publication: *Publication) !void {
    if (!publication.isPristineForComposition()) return error.InvalidOwner;
    if (!validAuditSeal(audit_seal)) return error.InvalidAudit;
    try steps.validateSuffixPreflight(publication, deadline, audit_seal);
    if (!publication.isPristineForComposition()) return error.InvalidOwner;

    publication.owner = publication;
    publication.audit_seal = audit_seal;
    steps.validateAuthority(deadline, audit_seal) catch |err| return failLocal(steps, publication, err);
    if (!publication.runningShapeIsCanonical()) return failLocal(steps, publication, error.InvalidOwner);

    publication.attachment_attempted = true;
    steps.attachAssets(deadline) catch |err| {
        if (steps.attachmentRequiresAudit()) return requireAudit(publication, .attachment);
        return failLocal(steps, publication, err);
    };
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .attachment);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .attachment);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .attachment);

    publication.redownload_attempted = true;
    steps.validateRedownload(deadline) catch return requireAudit(publication, .attachment);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .attachment);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .attachment);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .attachment);

    publication.publication_attempted = true;
    steps.publishDraft(deadline) catch return requireAudit(publication, .publication);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .publication);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .publication);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .publication);

    publication.verification_attempted = true;
    steps.verifyPublished(deadline) catch return requireAudit(publication, .post_publish);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .post_publish);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .post_publish);
    if (!publication.runningShapeIsCanonical()) return requireAudit(publication, .post_publish);

    publication.successful = true;
}

pub fn cleanupWith(steps: anytype, publication: *Publication) !void {
    if (!publication.ownsCompletePublication()) return error.InvalidOwner;
    publication.successful = false;
    if (!unwind(steps, publication)) return error.CleanupFailed;
    publication.* = .{};
}

pub fn retryCleanupWith(steps: anytype, publication: *Publication) !void {
    if (!publication.needsCleanup()) return error.InvalidOwner;
    if (!unwind(steps, publication)) return error.CleanupFailed;
    publication.* = .{};
}

fn failLocal(steps: anytype, publication: *Publication, original: anyerror) anyerror {
    publication.successful = false;
    publication.audit_required = false;
    publication.audit_stage = .none;
    if (!unwind(steps, publication)) return error.CleanupFailed;
    publication.* = .{};
    return original;
}

fn requireAudit(publication: *Publication, stage: AuditStage) anyerror {
    publication.successful = false;
    publication.audit_required = true;
    publication.audit_stage = stage;
    return error.AuditRequired;
}

fn unwind(steps: anytype, publication: *Publication) bool {
    var clean = true;
    if (publication.verification_attempted) cleanOne(steps, publication, .verification, &clean);
    if (publication.publication_attempted) cleanOne(steps, publication, .publication, &clean);
    if (publication.redownload_attempted) cleanOne(steps, publication, .redownload, &clean);
    if (publication.attachment_attempted) cleanOne(steps, publication, .attachment, &clean);
    return clean and !publication.anyAttempted();
}

const LocalOwner = enum { attachment, redownload, publication, verification };

fn cleanOne(steps: anytype, publication: *Publication, comptime owner: LocalOwner, clean: *bool) void {
    const released = switch (owner) {
        .attachment => result: {
            steps.cleanupAttachment() catch {
                clean.* = false;
                break :result false;
            };
            break :result true;
        },
        .redownload => result: {
            steps.cleanupRedownload() catch {
                clean.* = false;
                break :result false;
            };
            break :result true;
        },
        .publication => result: {
            steps.cleanupPublication() catch {
                clean.* = false;
                break :result false;
            };
            break :result true;
        },
        .verification => result: {
            steps.cleanupVerification() catch {
                clean.* = false;
                break :result false;
            };
            break :result true;
        },
    };
    if (!released) return;
    switch (owner) {
        .attachment => publication.attachment_attempted = false,
        .redownload => publication.redownload_attempted = false,
        .publication => publication.publication_attempted = false,
        .verification => publication.verification_attempted = false,
    }
}

fn validAuditSeal(seal: [32]u8) bool {
    return !std.mem.allEqual(u8, &seal, 0);
}
