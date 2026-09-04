const std = @import("std");
const phase = @import("release_adapter_candidate_publication_phase");

test "publication owns exact order on one borrowed deadline" {
    std.testing.refAllDecls(phase);
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try phase.executeWith(&steps, &deadline, &publication);
    try std.testing.expect(publication.ownsCompletePublication());
    try std.testing.expectEqualStrings("preflight,audit,fence,manifest,fence,attest,fence,attach,fence,redownload,fence,publish,fence,verify,fence", steps.log());
    try std.testing.expectEqual(@as(usize, 7), steps.deadline_observations);
}

test "publication rejects pre-owned and copied owners before callbacks" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    publication.owner = &publication;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &publication));
    var copied = publication;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &copied));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
}

test "preflight and audit capture failures are side effect free" {
    var deadline: u8 = 0;
    inline for (.{ Point.preflight, Point.audit }) |point| {
        var steps = Steps{ .fail_at = point };
        var publication: phase.Publication = .{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &deadline, &publication));
        try std.testing.expect(publication.isPristineForComposition());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
    }
    var mutated_preflight = Steps{ .fail_at = .preflight, .mutate_preflight = true };
    var preflight_publication: phase.Publication = .{};
    try std.testing.expectError(error.Injected, phase.executeWith(&mutated_preflight, &deadline, &preflight_publication));
    try std.testing.expect(preflight_publication.isPristineForComposition());
    var mutated_audit = Steps{ .fail_at = .audit, .mutate_audit = true };
    var audit_publication: phase.Publication = .{};
    try std.testing.expectError(error.Injected, phase.executeWith(&mutated_audit, &deadline, &audit_publication));
    try std.testing.expect(audit_publication.isPristineForComposition());
}

test "empty audit seal and preflight mutation fail before leaves" {
    var deadline: u8 = 0;
    var steps = Steps{ .empty_audit = true };
    var publication: phase.Publication = .{};
    try std.testing.expectError(error.InvalidAudit, phase.executeWith(&steps, &deadline, &publication));
    try std.testing.expect(publication.isPristineForComposition());
    steps = .{ .mutate_preflight = true };
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &publication));
    try std.testing.expectEqualStrings("preflight", steps.log());
    steps = .{ .mutate_audit = true };
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &publication));
    try std.testing.expect(publication.isPristineForComposition());
    try std.testing.expectEqualStrings("preflight,audit", steps.log());
    steps = .{ .alias_audit = true };
    try std.testing.expectError(error.InvalidAudit, phase.executeWith(&steps, &deadline, &publication));
    try std.testing.expect(publication.isPristineForComposition());
    steps = .{ .oversized_audit = true };
    try std.testing.expectError(error.InvalidAudit, phase.executeWith(&steps, &deadline, &publication));
    try std.testing.expect(publication.isPristineForComposition());
}

test "local failures unwind attempted owners in reverse order" {
    var deadline: u8 = 0;
    const cases = [_]struct { point: Point, expected: []const u8 }{
        .{ .point = .manifest, .expected = "preflight,audit,fence,manifest,clean-manifest" },
        .{ .point = .attest, .expected = "preflight,audit,fence,manifest,fence,attest,clean-attest,clean-manifest" },
        .{ .point = .attach_empty, .expected = "preflight,audit,fence,manifest,fence,attest,fence,attach,clean-attach,clean-attest,clean-manifest" },
    };
    for (cases) |case| {
        var steps = Steps{ .fail_at = case.point };
        var publication: phase.Publication = .{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &deadline, &publication));
        try std.testing.expectEqualStrings(case.expected, steps.log());
        try std.testing.expect(publication.isPristineForComposition());
    }
}

test "terminal attachment failure preserves audit state without cleanup" {
    var deadline: u8 = 0;
    var steps = Steps{ .fail_at = .attach_terminal };
    var publication: phase.Publication = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &publication));
    try std.testing.expect(publication.needsAudit());
    try std.testing.expectEqual(phase.AuditStage.attachment, publication.auditStage());
    try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
}

test "every failure after attachment success is terminal and non-retryable" {
    var deadline: u8 = 0;
    inline for (.{ Point.redownload, Point.publish, Point.verify, Point.final_fence }) |point| {
        var steps = Steps{ .fail_at = point };
        var publication: phase.Publication = .{};
        try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &publication));
        try std.testing.expect(publication.needsAudit());
        try std.testing.expectEqual(if (point == .verify or point == .final_fence) phase.AuditStage.post_publish else if (point == .publish) phase.AuditStage.publication else phase.AuditStage.attachment, publication.auditStage());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
        try std.testing.expectError(error.InvalidOwner, phase.retryCleanupWith(&steps, &publication));
    }
}

test "successful cleanup closes local capabilities in reverse order" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try phase.executeWith(&steps, &deadline, &publication);
    steps.length = 0;
    try phase.cleanupWith(&steps, &publication);
    try std.testing.expectEqualStrings("clean-verify,clean-publish,clean-redownload,clean-attach,clean-attest,clean-manifest", steps.log());
    try std.testing.expect(publication.isPristineForComposition());
}

test "cleanup failure preserves only the exact retry set" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try phase.executeWith(&steps, &deadline, &publication);
    steps.length = 0;
    steps.cleanup_fail = .attachment;
    try std.testing.expectError(error.CleanupFailed, phase.cleanupWith(&steps, &publication));
    try std.testing.expect(publication.needsCleanup());
    try std.testing.expect(!publication.verification_attempted);
    try std.testing.expect(!publication.publication_attempted);
    try std.testing.expect(!publication.redownload_attempted);
    try std.testing.expect(publication.attachment_attempted);
    try std.testing.expect(!publication.attestation_attempted);
    try std.testing.expect(!publication.manifest_attempted);
    steps.cleanup_fail = .none;
    try phase.retryCleanupWith(&steps, &publication);
    try std.testing.expect(publication.isPristineForComposition());
}

test "foreign deadline before and after remote mutation follows the safe boundary" {
    var deadline: u8 = 0;
    var local_steps = Steps{ .foreign_at = 3 };
    var local: phase.Publication = .{};
    try std.testing.expectError(error.ForeignDeadline, phase.executeWith(&local_steps, &deadline, &local));
    try std.testing.expect(local.isPristineForComposition());
    var remote_steps = Steps{ .foreign_at = 6 };
    var remote: phase.Publication = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&remote_steps, &deadline, &remote));
    try std.testing.expect(remote.needsAudit());
}

const Point = enum { none, preflight, audit, manifest, attest, attach_empty, attach_terminal, redownload, publish, verify, final_fence };
const Cleanup = enum { none, manifest, attestation, attachment, redownload, publication, verification };

const Steps = struct {
    events: [1024]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    cleanup_fail: Cleanup = .none,
    expected_deadline: ?*u8 = null,
    deadline_observations: usize = 0,
    foreign_at: usize = 0,
    cleanup_count: usize = 0,
    empty_audit: bool = false,
    mutate_preflight: bool = false,
    mutate_audit: bool = false,
    alias_audit: bool = false,
    oversized_audit: bool = false,
    attach_terminal: bool = false,
    publication_target: ?*phase.Publication = null,
    audit_bytes: [4]u8 = .{ 1, 2, 3, 4 },

    fn add(self: *@This(), value: []const u8) void {
        if (self.length != 0) {
            self.events[self.length] = ',';
            self.length += 1;
        }
        @memcpy(self.events[self.length..][0..value.len], value);
        self.length += value.len;
    }
    fn log(self: *const @This()) []const u8 {
        return self.events[0..self.length];
    }
    pub fn validatePreflight(self: *@This(), publication: *phase.Publication, deadline: *u8) !void {
        self.add("preflight");
        if (self.mutate_preflight) publication.manifest_attempted = true;
        if (self.fail_at == .preflight) return error.Injected;
        self.publication_target = publication;
        self.expected_deadline = deadline;
    }
    pub fn captureAuditBytes(self: *@This(), deadline: *u8) ![]const u8 {
        self.add("audit");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        if (self.mutate_audit) self.publication_target.?.manifest_attempted = true;
        if (self.fail_at == .audit) return error.Injected;
        if (self.alias_audit) return std.mem.asBytes(self.publication_target.?);
        if (self.oversized_audit) return &oversized_audit_bytes;
        return if (self.empty_audit) self.audit_bytes[0..0] else &self.audit_bytes;
    }
    pub fn validateAuthority(self: *@This(), deadline: *u8, seal: [32]u8) !void {
        self.add("fence");
        if (deadline != self.expected_deadline or std.mem.allEqual(u8, &seal, 0)) return error.ForeignDeadline;
        self.deadline_observations += 1;
        if (self.foreign_at != 0 and self.deadline_observations == self.foreign_at) return error.ForeignDeadline;
        if (self.fail_at == .final_fence and self.deadline_observations == 7) return error.Injected;
    }
    pub fn authorManifest(self: *@This(), deadline: *u8) !void {
        try self.leaf("manifest", .manifest, deadline);
    }
    pub fn attestAuthored(self: *@This(), deadline: *u8) !void {
        try self.leaf("attest", .attest, deadline);
    }
    pub fn attachAssets(self: *@This(), deadline: *u8) !void {
        self.add("attach");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        if (self.fail_at == .attach_empty) return error.Injected;
        if (self.fail_at == .attach_terminal) {
            self.attach_terminal = true;
            return error.Injected;
        }
    }
    pub fn attachmentRequiresAudit(self: *const @This()) bool {
        return self.attach_terminal;
    }
    pub fn validateRedownload(self: *@This(), deadline: *u8) !void {
        try self.leaf("redownload", .redownload, deadline);
    }
    pub fn publishDraft(self: *@This(), deadline: *u8) !void {
        try self.leaf("publish", .publish, deadline);
    }
    pub fn verifyPublished(self: *@This(), deadline: *u8) !void {
        try self.leaf("verify", .verify, deadline);
    }
    fn leaf(self: *@This(), name: []const u8, point: Point, deadline: *u8) !void {
        self.add(name);
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        if (self.fail_at == point) return error.Injected;
    }
    pub fn cleanupManifest(self: *@This()) !void {
        try self.clean("clean-manifest", .manifest);
    }
    pub fn cleanupAttestation(self: *@This()) !void {
        try self.clean("clean-attest", .attestation);
    }
    pub fn cleanupAttachment(self: *@This()) !void {
        try self.clean("clean-attach", .attachment);
    }
    pub fn cleanupRedownload(self: *@This()) !void {
        try self.clean("clean-redownload", .redownload);
    }
    pub fn cleanupPublication(self: *@This()) !void {
        try self.clean("clean-publish", .publication);
    }
    pub fn cleanupVerification(self: *@This()) !void {
        try self.clean("clean-verify", .verification);
    }
    fn clean(self: *@This(), name: []const u8, target: Cleanup) !void {
        self.add(name);
        self.cleanup_count += 1;
        if (self.cleanup_fail == target) return error.InjectedCleanup;
    }
};

const oversized_audit_bytes = [_]u8{1} ** (phase.max_audit_bytes + 1);
