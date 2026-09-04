const std = @import("std");
const phase = @import("release_adapter_candidate_prerequisite_phase");

test "prerequisite preparation owns exact order on one borrowed deadline" {
    std.testing.refAllDecls(phase);
    var deadline: u8 = 0;
    var steps = Steps{};
    var preparation: phase.Preparation = .{};
    try phase.executeWith(&steps, &deadline, &preparation);
    try std.testing.expect(preparation.ownsCompletePrerequisites());
    try std.testing.expectEqualStrings("preflight,fence,attest,fence,draft,fence,files,fence,product,fence,source,fence,identity,fence,compatibility,fence", steps.log());
    try std.testing.expectEqual(@as(usize, 8), steps.deadline_observations);
}

test "pre-owned and preflight-mutated preparation run no leaves" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var preparation: phase.Preparation = .{};
    preparation.owner = &preparation;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &preparation));
    var copied = preparation;
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &copied));
    try std.testing.expectEqual(@as(usize, 0), steps.length);
    preparation = .{};
    steps = .{ .mutate_preflight = true };
    try std.testing.expectError(error.InvalidOwner, phase.executeWith(&steps, &deadline, &preparation));
    try std.testing.expect(preparation.isPristineForComposition());
    try std.testing.expectEqualStrings("preflight", steps.log());
}

test "pre-draft failures unwind attempted local owners" {
    var deadline: u8 = 0;
    inline for (.{ Point.initial_fence, Point.attest, Point.attest_fence, Point.draft_empty }) |point| {
        var steps = Steps{ .fail_at = point };
        var preparation: phase.Preparation = .{};
        try std.testing.expectError(error.Injected, phase.executeWith(&steps, &deadline, &preparation));
        try std.testing.expect(preparation.isPristineForComposition());
        if (point == .initial_fence) try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
        if (point == .attest or point == .attest_fence or point == .draft_empty)
            try std.testing.expectEqual(@as(usize, 1), steps.cleanup_count);
    }
}

test "pre-draft cleanup failure preserves exact retry set" {
    var deadline: u8 = 0;
    var steps = Steps{ .fail_at = .draft_empty, .cleanup_fail = .attestation };
    var preparation: phase.Preparation = .{};
    try std.testing.expectError(error.CleanupFailed, phase.executeWith(&steps, &deadline, &preparation));
    try std.testing.expect(preparation.needsCleanup());
    try std.testing.expect(preparation.attestation_attempted);
    try std.testing.expect(!preparation.draft_attempted);
    steps.cleanup_fail = .none;
    try phase.retryCleanupWith(&steps, &preparation);
    try std.testing.expect(preparation.isPristineForComposition());
}

test "draft mutation ambiguity is terminal and non-retryable" {
    var deadline: u8 = 0;
    inline for (.{ Point.draft_unknown, Point.draft_known }) |point| {
        var steps = Steps{ .fail_at = point };
        var preparation: phase.Preparation = .{};
        try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &preparation));
        try std.testing.expect(preparation.needsAudit());
        try std.testing.expectEqual(phase.AuditStage.draft, preparation.auditStage());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
        try std.testing.expectError(error.InvalidOwner, phase.retryCleanupWith(&steps, &preparation));
    }
}

test "all failures after ready draft preserve exact terminal stage" {
    var deadline: u8 = 0;
    inline for (.{ Point.draft_fence, Point.files, Point.files_fence, Point.product, Point.product_fence, Point.source, Point.source_fence, Point.identity, Point.identity_fence, Point.compatibility, Point.final_fence }) |point| {
        var steps = Steps{ .fail_at = point };
        var preparation: phase.Preparation = .{};
        try std.testing.expectError(error.AuditRequired, phase.executeWith(&steps, &deadline, &preparation));
        try std.testing.expect(preparation.needsAudit());
        try std.testing.expectEqual(stageFor(point), preparation.auditStage());
        try std.testing.expectEqual(@as(usize, 0), steps.cleanup_count);
    }
}

test "successful cleanup closes only local capabilities in reverse order" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var preparation: phase.Preparation = .{};
    try phase.executeWith(&steps, &deadline, &preparation);
    steps.length = 0;
    try phase.cleanupWith(&steps, &preparation);
    try std.testing.expectEqualStrings("clean-compatibility,clean-identity,clean-source,clean-product,clean-files,clean-draft,clean-attest", steps.log());
    try std.testing.expect(preparation.isPristineForComposition());
}

test "successful cleanup failure is retryable without repeating remote mutation" {
    var deadline: u8 = 0;
    var steps = Steps{};
    var preparation: phase.Preparation = .{};
    try phase.executeWith(&steps, &deadline, &preparation);
    steps.length = 0;
    steps.cleanup_fail = .product;
    try std.testing.expectError(error.CleanupFailed, phase.cleanupWith(&steps, &preparation));
    try std.testing.expect(preparation.needsCleanup());
    try std.testing.expect(preparation.product_attempted);
    try std.testing.expect(!preparation.compatibility_attempted);
    try std.testing.expect(!preparation.identity_attempted);
    try std.testing.expect(!preparation.source_attempted);
    steps.cleanup_fail = .none;
    try phase.retryCleanupWith(&steps, &preparation);
    try std.testing.expect(preparation.isPristineForComposition());
    try std.testing.expectEqual(@as(usize, 1), steps.draft_calls);
}

fn stageFor(point: Point) phase.AuditStage {
    return switch (point) {
        .draft_fence => .draft,
        .files, .files_fence => .files,
        .product, .product_fence => .product,
        .source, .source_fence => .source,
        .identity, .identity_fence => .identity,
        .compatibility, .final_fence => .compatibility,
        else => unreachable,
    };
}

const Point = enum {
    none,
    initial_fence,
    attest,
    attest_fence,
    draft_empty,
    draft_unknown,
    draft_known,
    draft_fence,
    files,
    files_fence,
    product,
    product_fence,
    source,
    source_fence,
    identity,
    identity_fence,
    compatibility,
    final_fence,
};
const Cleanup = enum { none, attestation, draft, files, product, source, identity, compatibility };

const Steps = struct {
    events: [1024]u8 = undefined,
    length: usize = 0,
    fail_at: Point = .none,
    cleanup_fail: Cleanup = .none,
    expected_deadline: ?*u8 = null,
    preparation: ?*phase.Preparation = null,
    deadline_observations: usize = 0,
    cleanup_count: usize = 0,
    draft_calls: usize = 0,
    draft_terminal: bool = false,
    mutate_preflight: bool = false,

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
    pub fn validatePreflight(self: *@This(), preparation: *phase.Preparation, deadline: *u8) !void {
        self.add("preflight");
        self.preparation = preparation;
        self.expected_deadline = deadline;
        if (self.mutate_preflight) preparation.attestation_attempted = true;
    }
    pub fn validateAuthority(self: *@This(), deadline: *u8) !void {
        self.add("fence");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        self.deadline_observations += 1;
        const point = switch (self.deadline_observations) {
            1 => Point.initial_fence,
            2 => .attest_fence,
            3 => .draft_fence,
            4 => .files_fence,
            5 => .product_fence,
            6 => .source_fence,
            7 => .identity_fence,
            8 => .final_fence,
            else => unreachable,
        };
        if (self.fail_at == point) return error.Injected;
    }
    pub fn attestCandidate(self: *@This(), deadline: *u8) !void {
        try self.leaf("attest", .attest, deadline);
    }
    pub fn createDraft(self: *@This(), deadline: *u8) !void {
        self.draft_calls += 1;
        self.add("draft");
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        if (self.fail_at == .draft_empty) return error.Injected;
        if (self.fail_at == .draft_unknown or self.fail_at == .draft_known) {
            self.draft_terminal = true;
            return error.Injected;
        }
    }
    pub fn draftRequiresAudit(self: *const @This()) bool {
        return self.draft_terminal;
    }
    pub fn bindFiles(self: *@This(), deadline: *u8) !void {
        try self.leaf("files", .files, deadline);
    }
    pub fn observeProduct(self: *@This(), deadline: *u8) !void {
        try self.leaf("product", .product, deadline);
    }
    pub fn observeSource(self: *@This(), deadline: *u8) !void {
        try self.leaf("source", .source, deadline);
    }
    pub fn composeIdentity(self: *@This(), deadline: *u8) !void {
        try self.leaf("identity", .identity, deadline);
    }
    pub fn probeCompatibility(self: *@This(), deadline: *u8) !void {
        try self.leaf("compatibility", .compatibility, deadline);
    }
    fn leaf(self: *@This(), name: []const u8, point: Point, deadline: *u8) !void {
        self.add(name);
        if (deadline != self.expected_deadline) return error.ForeignDeadline;
        if (self.fail_at == point) return error.Injected;
    }
    pub fn cleanupAttestation(self: *@This()) !void {
        try self.clean("clean-attest", .attestation);
    }
    pub fn cleanupDraft(self: *@This()) !void {
        try self.clean("clean-draft", .draft);
    }
    pub fn cleanupFiles(self: *@This()) !void {
        try self.clean("clean-files", .files);
    }
    pub fn cleanupProduct(self: *@This()) !void {
        try self.clean("clean-product", .product);
    }
    pub fn cleanupSource(self: *@This()) !void {
        try self.clean("clean-source", .source);
    }
    pub fn cleanupIdentity(self: *@This()) !void {
        try self.clean("clean-identity", .identity);
    }
    pub fn cleanupCompatibility(self: *@This()) !void {
        try self.clean("clean-compatibility", .compatibility);
    }
    fn clean(self: *@This(), name: []const u8, target: Cleanup) !void {
        self.add(name);
        self.cleanup_count += 1;
        if (self.cleanup_fail == target) return error.InjectedCleanup;
    }
};
