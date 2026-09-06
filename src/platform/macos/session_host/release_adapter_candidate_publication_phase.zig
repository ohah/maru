//! Closed candidate publication transaction.
//!
//! Leaf adapters retain GitHub, filesystem, and semantic authority. This owner fixes their order,
//! one borrowed deadline identity, local reverse cleanup, and the point after which remote state
//! forbids automatic retry.

const std = @import("std");
const suffix_phase = @import("release_adapter_candidate_publication_suffix_phase");

pub const AuditStage = suffix_phase.AuditStage;
pub const SuffixPublication = suffix_phase.Publication;
pub const max_audit_bytes: usize = 16 * 1024;
const audit_domain = "maru.session-host.candidate-publication.audit.v1";

pub const Publication = struct {
    owner: ?*Publication = null,
    audit_seal: [32]u8 = @splat(0),
    manifest_attempted: bool = false,
    attestation_attempted: bool = false,
    suffix: suffix_phase.Publication = .{},

    pub fn ownsCompletePublication(self: *const @This()) bool {
        return self.owner == self and validAuditSeal(self.audit_seal) and self.manifest_attempted and
            self.attestation_attempted and self.suffix.ownsCompletePublication() and
            std.mem.eql(u8, &self.audit_seal, &self.suffix.audit_seal);
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and validAuditSeal(self.audit_seal) and self.manifest_attempted and
            self.attestation_attempted and self.suffix.needsAudit() and
            std.mem.eql(u8, &self.audit_seal, &self.suffix.audit_seal);
    }

    pub fn auditStage(self: *const @This()) AuditStage {
        return if (self.needsAudit()) self.suffix.auditStage() else .none;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        if (self.owner != self or !validAuditSeal(self.audit_seal) or self.suffix.needsAudit()) return false;
        if (self.suffix.needsCleanup())
            return std.mem.eql(u8, &self.audit_seal, &self.suffix.audit_seal);
        return self.suffix.isPristineForComposition() and (self.manifest_attempted or self.attestation_attempted);
    }

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and std.mem.allEqual(u8, &self.audit_seal, 0) and
            !self.manifest_attempted and !self.attestation_attempted and self.suffix.isPristineForComposition();
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

    suffix_phase.executeWith(steps, deadline, audit_seal, &publication.suffix) catch |err| {
        if (publication.suffix.needsAudit()) return error.AuditRequired;
        if (publication.suffix.needsCleanup()) {
            _ = unwindPrefix(steps, publication);
            return error.CleanupFailed;
        }
        return failLocal(steps, publication, err);
    };
}

pub fn cleanupWith(steps: anytype, publication: *Publication) !void {
    if (!publication.ownsCompletePublication()) return error.InvalidOwner;
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

fn unwind(steps: anytype, publication: *Publication) bool {
    var clean = true;
    if (publication.suffix.ownsCompletePublication()) {
        suffix_phase.cleanupWith(steps, &publication.suffix) catch {
            clean = false;
        };
    } else if (publication.suffix.needsCleanup()) {
        suffix_phase.retryCleanupWith(steps, &publication.suffix) catch {
            clean = false;
        };
    } else if (!publication.suffix.isPristineForComposition()) {
        clean = false;
    }
    if (!unwindPrefix(steps, publication)) clean = false;
    return clean and publication.suffix.isPristineForComposition() and
        !publication.attestation_attempted and !publication.manifest_attempted;
}

fn unwindPrefix(steps: anytype, publication: *Publication) bool {
    var clean = true;
    if (publication.attestation_attempted) cleanOne(steps, publication, .attestation, &clean);
    if (publication.manifest_attempted) cleanOne(steps, publication, .manifest, &clean);
    return clean and !publication.attestation_attempted and !publication.manifest_attempted;
}

const LocalOwner = enum { manifest, attestation };

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
    };
    if (!released) return;
    switch (owner) {
        .manifest => publication.manifest_attempted = false,
        .attestation => publication.attestation_attempted = false,
    }
}

fn validAuditSeal(seal: [32]u8) bool {
    return !std.mem.allEqual(u8, &seal, 0);
}

pub fn deriveAuditSeal(bytes: []const u8) [32]u8 {
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
