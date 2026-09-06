//! The publication suffix is shared by fresh and resumed release paths. These tests keep the
//! remote-mutation boundary and cleanup policy independent of either concrete product owner.

const std = @import("std");
const phase = @import("release_adapter_candidate_publication_suffix_phase");

test "suffix owns exact remote order on one deadline and seal" {
    std.testing.refAllDecls(phase);
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try phase.executeWith(&steps, &deadline, seal, &publication);
    try std.testing.expect(publication.ownsCompletePublication());
    try std.testing.expectEqualStrings("fence,attach,fence,redownload,fence,publish,fence,verify,fence", steps.log());
    try std.testing.expectEqual(@as(usize, 5), steps.fence_count);
}

test "suffix rejects invalid seal and pre-owned or copied owner before callbacks" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try std.testing.expectError(error.InvalidAudit, phase.executeWith(&steps, &deadline, zero_seal, &publication));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
    publication.owner = &publication;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, seal, &publication));
    var copied = publication;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, seal, &copied));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
}

test "first fence and empty attachment failure remain local and pristine" {
    var deadline: u8 = 0;
    inline for (.{ Point.first_fence, Point.attach_empty }) |point| {
        var steps = Steps{ .fail_at = point };
        var publication: phase.Publication = .{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &deadline, seal, &publication));
        try std.testing.expect(publication.isPristineForComposition());
        try std.testing.expect(!publication.needsAudit());
        try std.testing.expectEqual(if (point == .attach_empty) @as(usize, 1) else 0, steps.cleanup_count);
    }
}

test "terminal attachment and every later failure retain exact audit stage" {
    var deadline: u8 = 0;
    const cases = [_]struct { point: Point, stage: phase.AuditStage }{
        .{ .point = .attach_terminal, .stage = .attachment },
        .{ .point = .after_attach_fence, .stage = .attachment },
        .{ .point = .redownload, .stage = .attachment },
        .{ .point = .after_redownload_fence, .stage = .attachment },
        .{ .point = .publish, .stage = .publication },
        .{ .point = .after_publish_fence, .stage = .publication },
        .{ .point = .verify, .stage = .post_publish },
        .{ .point = .final_fence, .stage = .post_publish },
    };
    for (cases) |case| {
        var steps = Steps{ .fail_at = case.point };
        var publication: phase.Publication = .{};
        try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, seal, &publication));
        try std.testing.expect(publication.needsAudit());
        try std.testing.expectEqual(case.stage, publication.auditStage());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
        try std.testing.expectError(error.InvalidOwner, phase.retryCleanupWith(&steps, &publication));
    }
}

test "successful cleanup closes the four local capabilities in reverse order" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try phase.executeWith(&steps, &deadline, seal, &publication);
    steps.length = 0;
    try phase.cleanupWith(&steps, &publication);
    try std.testing.expectEqualStrings("clean-verify,clean-publish,clean-redownload,clean-attach", steps.log());
    try std.testing.expect(publication.isPristineForComposition());
}

test "cleanup failure continues and preserves only the failed owner for retry" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var publication: phase.Publication = .{};
    try phase.executeWith(&steps, &deadline, seal, &publication);
    steps.length = 0;
    steps.cleanup_fail = .attachment;
    try std.testing.expectError(error.CleanupFailed, phase.cleanupWith(&steps, &publication));
    try std.testing.expectEqualStrings("clean-verify,clean-publish,clean-redownload,clean-attach", steps.log());
    try std.testing.expect(publication.needsCleanup());
    try std.testing.expect(!publication.verification_attempted);
    try std.testing.expect(!publication.publication_attempted);
    try std.testing.expect(!publication.redownload_attempted);
    try std.testing.expect(publication.attachment_attempted);
    steps.cleanup_fail = .none;
    steps.length = 0;
    try phase.retryCleanupWith(&steps, &publication);
    try std.testing.expectEqualStrings("clean-attach", steps.log());
    try std.testing.expect(publication.isPristineForComposition());
}

test "each cleanup position leaves exactly its own failed subset" {
    var deadline: u8 = 0;
    inline for (.{ Cleanup.verification, Cleanup.publication, Cleanup.redownload, Cleanup.attachment }) |target| {
        var steps = Steps{};
        var publication: phase.Publication = .{};
        try phase.executeWith(&steps, &deadline, seal, &publication);
        steps.cleanup_fail = target;
        try std.testing.expectError(error.CleanupFailed, phase.cleanupWith(&steps, &publication));
        try std.testing.expectEqual(target == .verification, publication.verification_attempted);
        try std.testing.expectEqual(target == .publication, publication.publication_attempted);
        try std.testing.expectEqual(target == .redownload, publication.redownload_attempted);
        try std.testing.expectEqual(target == .attachment, publication.attachment_attempted);
    }
}

test "foreign deadline before remote mutation is local but afterwards requires audit" {
    var deadline: u8 = 0;
    var local_steps = Steps{ .foreign_at = 1 };
    var local: phase.Publication = .{};
    try std.testing.expectError(error.ForeignDeadline, phase.executeWith(&local_steps, &deadline, seal, &local));
    try std.testing.expect(local.isPristineForComposition());
    var remote_steps = Steps{ .foreign_at = 2 };
    var remote: phase.Publication = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&remote_steps, &deadline, seal, &remote));
    try std.testing.expectEqual(phase.AuditStage.attachment, remote.auditStage());
}

test "seal drift before remote mutation is local but afterwards requires audit" {
    var deadline: u8 = 0;
    var local_steps = Steps{ .drift_seal_at = 1 };
    var local: phase.Publication = .{};
    try std.testing.expectError(error.AuthorityChanged, phase.executeWith(&local_steps, &deadline, seal, &local));
    try std.testing.expect(local.isPristineForComposition());
    var remote_steps = Steps{ .drift_seal_at = 2 };
    var remote: phase.Publication = .{};
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&remote_steps, &deadline, seal, &remote));
    try std.testing.expectEqual(phase.AuditStage.attachment, remote.auditStage());
}

test "state mutation during a leaf fails closed at the matching remote boundary" {
    var deadline: u8 = 0;
    var steps = Steps{ .mutate_at = .redownload };
    var publication: phase.Publication = .{};
    steps.publication = &publication;
    try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, seal, &publication));
    try std.testing.expectEqual(phase.AuditStage.attachment, publication.auditStage());
}

test "fresh publication delegates the remote policy to this suffix exactly once" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_candidate_publication_phase.zig", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "suffix_phase.executeWith("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "suffix_phase.cleanupWith("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "suffix_phase.retryCleanupWith("));
    inline for (.{ ".attachAssets(", ".validateRedownload(", ".publishDraft(", ".verifyPublished(" }) |parallel_leaf|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, parallel_leaf));
    inline for (.{ "publication.attachment_attempted", "publication.redownload_attempted", "publication.publication_attempted", "publication.verification_attempted" }) |parallel_policy|
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, parallel_policy));
}

const Point = enum { none, first_fence, attach_empty, attach_terminal, after_attach_fence, redownload, after_redownload_fence, publish, after_publish_fence, verify, final_fence };
const Cleanup = enum { none, attachment, redownload, publication, verification };
const seal = [_]u8{7} ** 32;
const zero_seal = [_]u8{0} ** 32;

const Steps = struct {
    events: [512]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    cleanup_fail: Cleanup = .none,
    expected_deadline: ?*u8 = null,
    expected_seal: [32]u8 = seal,
    fence_count: usize = 0,
    foreign_at: usize = 0,
    drift_seal_at: usize = 0,
    cleanup_count: usize = 0,
    terminal_attachment: bool = false,
    mutate_at: Point = .none,
    publication: ?*phase.Publication = null,

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
    pub fn validateSuffixPreflight(self: *@This(), publication: *phase.Publication, deadline: *u8, audit_seal: [32]u8) !void {
        if (self.expected_deadline == null) self.expected_deadline = deadline;
        if (deadline != self.expected_deadline or !std.mem.eql(u8, &audit_seal, &self.expected_seal)) return error.ForeignDeadline;
        if (self.publication == null) self.publication = publication;
        if (publication != self.publication) return error.InvalidOwner;
    }
    pub fn validateAuthority(self: *@This(), deadline: *u8, audit_seal: [32]u8) !void {
        self.add("fence");
        self.fence_count += 1;
        if (deadline != self.expected_deadline or self.foreign_at == self.fence_count) return error.ForeignDeadline;
        if (self.drift_seal_at == self.fence_count or !std.mem.eql(u8, &audit_seal, &self.expected_seal)) return error.AuthorityChanged;
        const point: Point = switch (self.fence_count) {
            1 => .first_fence,
            2 => .after_attach_fence,
            3 => .after_redownload_fence,
            4 => .after_publish_fence,
            5 => .final_fence,
            else => unreachable,
        };
        if (self.fail_at == point) return error.Injected;
    }
    pub fn attachAssets(self: *@This(), deadline: *u8) !void {
        try self.leaf("attach", .attach_empty, deadline);
        if (self.fail_at == .attach_terminal) {
            self.terminal_attachment = true;
            return error.Injected;
        }
    }
    pub fn attachmentRequiresAudit(self: *const @This()) bool {
        return self.terminal_attachment;
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
        if (self.mutate_at == point) self.publication.?.successful = true;
        if (self.fail_at == point) return error.Injected;
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
