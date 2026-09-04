//! Closed candidate publication transaction.
//!
//! Leaf adapters retain GitHub, filesystem, and semantic authority. This owner fixes their order,
//! one borrowed deadline identity, local reverse cleanup, and the point after which remote state
//! forbids automatic retry.

const std = @import("std");

pub const AuditStage = enum { none, attachment, publication, post_publish };
pub const max_audit_bytes: usize = 16 * 1024;
const audit_domain = "maru.session-host.candidate-publication.audit.v1";

pub const Publication = struct {
    owner: ?*Publication = null,
    audit_seal: [32]u8 = @splat(0),
    manifest_attempted: bool = false,
    attestation_attempted: bool = false,
    attachment_attempted: bool = false,
    redownload_attempted: bool = false,
    publication_attempted: bool = false,
    verification_attempted: bool = false,
    successful: bool = false,
    audit_required: bool = false,
    audit_stage: AuditStage = .none,

    pub fn ownsCompletePublication(self: *const @This()) bool {
        return self.owner == self and self.successful and !self.audit_required and
            self.audit_stage == .none and validAuditSeal(self.audit_seal) and self.allAttempted();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and !self.successful and self.audit_required and
            self.audit_stage != .none and validAuditSeal(self.audit_seal);
    }

    pub fn auditStage(self: *const @This()) AuditStage {
        return if (self.needsAudit()) self.audit_stage else .none;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.successful and !self.audit_required and
            self.audit_stage == .none and validAuditSeal(self.audit_seal) and self.anyAttempted();
    }

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and std.mem.allEqual(u8, &self.audit_seal, 0) and
            !self.anyAttempted() and !self.successful and !self.audit_required and self.audit_stage == .none;
    }

    fn anyAttempted(self: *const @This()) bool {
        return self.manifest_attempted or self.attestation_attempted or self.attachment_attempted or
            self.redownload_attempted or self.publication_attempted or self.verification_attempted;
    }

    fn allAttempted(self: *const @This()) bool {
        return self.manifest_attempted and self.attestation_attempted and self.attachment_attempted and
            self.redownload_attempted and self.publication_attempted and self.verification_attempted;
    }
};

pub fn executeWith(steps: anytype, deadline: anytype, publication: *Publication) !void {
    if (!publication.pristine()) return error.InvalidOwner;
    steps.validatePreflight(publication, deadline) catch |err| {
        publication.* = .{};
        return err;
    };
    if (!publication.pristine()) {
        publication.* = .{};
        return error.InvalidOwner;
    }
    const audit_bytes = steps.captureAuditBytes(deadline) catch |err| {
        publication.* = .{};
        return err;
    };
    if (!publication.pristine()) {
        publication.* = .{};
        return error.InvalidOwner;
    }
    if (audit_bytes.len == 0 or audit_bytes.len > max_audit_bytes or overlaps(std.mem.asBytes(publication), audit_bytes)) return error.InvalidAudit;
    const audit_seal = deriveAuditSeal(audit_bytes);
    publication.owner = publication;
    publication.audit_seal = audit_seal;

    steps.validateAuthority(deadline, audit_seal) catch |err| return failLocal(steps, publication, err);

    publication.manifest_attempted = true;
    steps.authorManifest(deadline) catch |err| return failLocal(steps, publication, err);
    steps.validateAuthority(deadline, audit_seal) catch |err| return failLocal(steps, publication, err);

    publication.attestation_attempted = true;
    steps.attestAuthored(deadline) catch |err| return failLocal(steps, publication, err);
    steps.validateAuthority(deadline, audit_seal) catch |err| return failLocal(steps, publication, err);

    publication.attachment_attempted = true;
    steps.attachAssets(deadline) catch |err| {
        if (steps.attachmentRequiresAudit()) return requireAudit(publication, .attachment);
        return failLocal(steps, publication, err);
    };
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .attachment);

    publication.redownload_attempted = true;
    steps.validateRedownload(deadline) catch return requireAudit(publication, .attachment);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .attachment);

    publication.publication_attempted = true;
    steps.publishDraft(deadline) catch return requireAudit(publication, .publication);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .publication);

    publication.verification_attempted = true;
    steps.verifyPublished(deadline) catch return requireAudit(publication, .post_publish);
    steps.validateAuthority(deadline, audit_seal) catch return requireAudit(publication, .post_publish);

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
    if (publication.attestation_attempted) cleanOne(steps, publication, .attestation, &clean);
    if (publication.manifest_attempted) cleanOne(steps, publication, .manifest, &clean);
    return clean and !publication.anyAttempted();
}

const LocalOwner = enum { manifest, attestation, attachment, redownload, publication, verification };

fn cleanOne(steps: anytype, publication: *Publication, comptime owner: LocalOwner, clean: *bool) void {
    const released = switch (owner) {
        .manifest => blk: {
            steps.cleanupManifest() catch {
                clean.* = false;
                break :blk false;
            };
            break :blk true;
        },
        .attestation => blk: {
            steps.cleanupAttestation() catch {
                clean.* = false;
                break :blk false;
            };
            break :blk true;
        },
        .attachment => blk: {
            steps.cleanupAttachment() catch {
                clean.* = false;
                break :blk false;
            };
            break :blk true;
        },
        .redownload => blk: {
            steps.cleanupRedownload() catch {
                clean.* = false;
                break :blk false;
            };
            break :blk true;
        },
        .publication => blk: {
            steps.cleanupPublication() catch {
                clean.* = false;
                break :blk false;
            };
            break :blk true;
        },
        .verification => blk: {
            steps.cleanupVerification() catch {
                clean.* = false;
                break :blk false;
            };
            break :blk true;
        },
    };
    if (!released) return;
    switch (owner) {
        .manifest => publication.manifest_attempted = false,
        .attestation => publication.attestation_attempted = false,
        .attachment => publication.attachment_attempted = false,
        .redownload => publication.redownload_attempted = false,
        .publication => publication.publication_attempted = false,
        .verification => publication.verification_attempted = false,
    }
}

fn validAuditSeal(seal: [32]u8) bool {
    return !std.mem.allEqual(u8, &seal, 0);
}

fn deriveAuditSeal(bytes: []const u8) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(audit_domain);
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    hasher.update(&length);
    hasher.update(bytes);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}
