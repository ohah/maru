const std = @import("std");
const product = @import("release_adapter_profile_stage3_preparation_product");

const Event = enum {
    start_deadline,
    preflight,
    validate_profile,
    author_manifest,
    promote_durable,
    fence_durable,
    close_retaining,
    cleanup_durable,
    cleanup_manifest,
    cleanup_deadline,
};

const Fake = struct {
    events: []Event = undefined,
    count: usize = 0,
    fail_event: ?Event = null,
    fail_validation: usize = 0,
    validation_count: usize = 0,
    retained: bool = false,

    fn record(self: *@This(), event: Event) !void {
        self.events[self.count] = event;
        self.count += 1;
        if (event == .validate_profile) {
            self.validation_count += 1;
            if (self.fail_event == event and self.validation_count == self.fail_validation) return error.InjectedFailure;
        } else if (self.fail_event == event) return error.InjectedFailure;
    }

    pub fn startDeadline(self: *@This(), budget_ns: i128, deadline: *product.Deadline) !void {
        if (budget_ns <= 0 or !deadline.isPristineForComposition()) return error.InvalidBudget;
        try self.record(.start_deadline);
        deadline.* = .{ .owner = deadline, .started_ns = 1, .expires_ns = budget_ns + 1 };
    }
    pub fn validatePreflight(self: *@This(), transaction: *product.Transaction, deadline: *product.Deadline) !void {
        if (!transaction.isPristineForComposition() or deadline.owner != deadline) return error.InvalidOwner;
        try self.record(.preflight);
    }
    pub fn validateProfile(self: *@This(), _: *product.Deadline) !void {
        try self.record(.validate_profile);
    }
    pub fn authorManifest(self: *@This(), _: *product.Deadline) !void {
        try self.record(.author_manifest);
    }
    pub fn promoteDurable(self: *@This(), _: *product.Deadline) !void {
        try self.record(.promote_durable);
    }
    pub fn fenceDurable(self: *@This(), _: *product.Deadline) !void {
        try self.record(.fence_durable);
    }
    pub fn closeRetaining(self: *@This(), _: *product.Deadline) !void {
        try self.record(.close_retaining);
        self.retained = true;
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.retained;
    }
    pub fn cleanupDurable(self: *@This()) !void {
        try self.record(.cleanup_durable);
        self.retained = false;
    }
    pub fn cleanupManifest(self: *@This()) !void {
        try self.record(.cleanup_manifest);
    }
    pub fn cleanupDeadline(self: *@This(), deadline: *product.Deadline) !void {
        try self.record(.cleanup_deadline);
        deadline.* = .{};
    }
};

test "upgrade stage3 consumes a profile owner once and retains one durable preparation" {
    var fake = Fake{};
    var execution: product.Execution = .{};
    try product.runWith(&fake, 100, &execution);
    try std.testing.expect(execution.isPristineForComposition());
    try std.testing.expect(fake.retained);
    try std.testing.expectEqualSlices(Event, &.{
        .start_deadline,
        .preflight,
        .validate_profile,
        .author_manifest,
        .validate_profile,
        .promote_durable,
        .validate_profile,
        .fence_durable,
        .validate_profile,
        .close_retaining,
        .validate_profile,
        .cleanup_manifest,
        .cleanup_deadline,
    }, fake.events[0..fake.count]);
}

test "pre-retention failure preserves the borrowed profile and exposes exact audit stage" {
    var fake = Fake{ .fail_event = .promote_durable };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
    try std.testing.expectEqual(product.Stage.promote, execution.auditStage());
    try std.testing.expect(!execution.retainedCommit());
    try std.testing.expectEqual(@as(usize, 0), count(fake.events[0..fake.count], .cleanup_durable));
}

test "post-retention failure keeps the durable commit and retry cleans only local owners" {
    var fake = Fake{ .fail_event = .validate_profile, .fail_validation = 5 };
    var execution: product.Execution = .{};
    try std.testing.expectError(error.AuditRequired, product.runWith(&fake, 100, &execution));
    try std.testing.expect(execution.retainedCommit());
    try std.testing.expectEqual(product.Stage.retained_close, execution.auditStage());
    fake.fail_event = null;
    try product.retryAuditCleanupWith(&fake, &execution);
    try std.testing.expect(execution.localCleanupComplete());
    try std.testing.expectEqual(@as(usize, 0), count(fake.events[0..fake.count], .cleanup_durable));
    try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_manifest));
    try std.testing.expectEqual(@as(usize, 1), count(fake.events[0..fake.count], .cleanup_deadline));
}

test "product surface does not accept caller profile predecessor timing or success scalars" {
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/platform/macos/session_host/release_adapter_profile_stage3_preparation_product.zig", std.testing.allocator, .limited(256 * 1024));
    defer std.testing.allocator.free(source);
    inline for (.{ "profile:", "predecessor:", "timing:", "success:" }) |forbidden|
        try std.testing.expect(std.mem.indexOf(u8, source, "pub const Inputs = struct") == null or std.mem.indexOf(u8, source, forbidden) == null);
}

fn count(events: []const Event, expected: Event) usize {
    var result: usize = 0;
    for (events) |event| if (event == expected) {
        result += 1;
    };
    return result;
}
