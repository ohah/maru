//! A durable intent, tomb inventory, and completion receipt make aggregate cleanup restartable.

const std = @import("std");
const recovery = @import("release_adapter_candidate_aggregate_cleanup_recovery");

const Op = enum {
    validate,
    inspect_completion,
    publish_intent,
    sync_parent_after_intent,
    locate,
    rename,
    sync_parent_after_rename,
    inspect_inventory,
    unlink_4,
    unlink_3,
    unlink_2,
    unlink_1,
    unlink_0,
    sync_tomb,
    remove_tomb,
    sync_parent_after_tomb,
    publish_completion,
    sync_parent_after_completion,
    remove_intent,
    sync_parent_final,
    close,
};

const Model = struct {
    calls: std.ArrayList(Op) = .empty,
    fail_once: ?Op = null,
    original: bool = true,
    tomb: bool = false,
    intent: bool = false,
    completion: bool = false,
    present: [recovery.entry_count]bool = @splat(true),
    foreign: ?usize = null,
    unexpected: bool = false,
    malformed_intent: bool = false,

    fn hit(self: *@This(), op: Op) !void {
        try self.calls.append(std.testing.allocator, op);
        if (self.fail_once == op) {
            self.fail_once = null;
            return error.InjectedFailure;
        }
    }

    pub fn validate(self: *@This()) !void {
        try self.hit(.validate);
        if (!self.original or self.tomb or self.intent or self.completion) return error.InvalidState;
    }
    pub fn inspectCompletion(self: *@This()) !recovery.CompletionState {
        try self.hit(.inspect_completion);
        if (!self.completion) return .absent;
        return if (self.intent) .durable_with_intent else .durable;
    }
    pub fn publishIntent(self: *@This()) !void {
        try self.hit(.publish_intent);
        if (self.intent) return error.InvalidState;
        self.intent = true;
    }
    pub fn syncParentAfterIntent(self: *@This()) !void {
        try self.hit(.sync_parent_after_intent);
    }
    pub fn locate(self: *@This()) !recovery.Location {
        try self.hit(.locate);
        if (self.malformed_intent or !self.intent) return error.InvalidRecord;
        if (self.original and self.tomb) return .ambiguous;
        if (self.original) return .original;
        if (self.tomb) return .tomb;
        return .removed;
    }
    pub fn rename(self: *@This()) !void {
        try self.hit(.rename);
        if (!self.original or self.tomb) return error.InvalidState;
        self.original = false;
        self.tomb = true;
    }
    pub fn syncParentAfterRename(self: *@This()) !void {
        try self.hit(.sync_parent_after_rename);
    }
    pub fn inspectInventory(self: *@This()) !recovery.Inventory {
        try self.hit(.inspect_inventory);
        return .{ .present = self.present, .foreign = self.foreign, .unexpected = self.unexpected };
    }
    pub fn unlink(self: *@This(), index: usize) !void {
        const op: Op = @enumFromInt(@intFromEnum(Op.unlink_4) + (recovery.entry_count - 1 - index));
        try self.hit(op);
        if (!self.tomb or !self.present[index]) return error.InvalidState;
        self.present[index] = false;
    }
    pub fn syncTomb(self: *@This()) !void {
        try self.hit(.sync_tomb);
    }
    pub fn removeTomb(self: *@This()) !void {
        try self.hit(.remove_tomb);
        if (!self.tomb) return error.InvalidState;
        for (self.present) |present| if (present) return error.InvalidState;
        self.tomb = false;
    }
    pub fn syncParentAfterTomb(self: *@This()) !void {
        try self.hit(.sync_parent_after_tomb);
    }
    pub fn publishCompletion(self: *@This()) !void {
        try self.hit(.publish_completion);
        if (self.original or self.tomb) return error.InvalidState;
        self.completion = true;
    }
    pub fn syncParentAfterCompletion(self: *@This()) !void {
        try self.hit(.sync_parent_after_completion);
    }
    pub fn removeIntent(self: *@This()) !void {
        try self.hit(.remove_intent);
        if (!self.completion or !self.intent) return error.InvalidState;
        self.intent = false;
    }
    pub fn syncParentFinal(self: *@This()) !void {
        try self.hit(.sync_parent_final);
    }
    pub fn close(self: *@This()) !void {
        try self.hit(.close);
    }
    fn deinit(self: *@This()) void {
        self.calls.deinit(std.testing.allocator);
    }
};

const success_order = [_]Op{
    .validate,           .inspect_completion,           .publish_intent,    .sync_parent_after_intent, .locate,
    .rename,             .sync_parent_after_rename,     .inspect_inventory, .unlink_4,                 .sync_tomb,
    .inspect_inventory,  .unlink_3,                     .sync_tomb,         .inspect_inventory,        .unlink_2,
    .sync_tomb,          .inspect_inventory,            .unlink_1,          .sync_tomb,                .inspect_inventory,
    .unlink_0,           .sync_tomb,                    .inspect_inventory, .remove_tomb,              .sync_parent_after_tomb,
    .publish_completion, .sync_parent_after_completion, .remove_intent,     .sync_parent_final,        .close,
};

test "fresh cleanup publishes intent before rename and completion before intent removal" {
    var model = Model{};
    defer model.deinit();
    var owner: recovery.Recovery = .{};
    try std.testing.expectEqual(recovery.Outcome.success, try recovery.testing_api.begin(&model, &owner));
    try std.testing.expectEqualSlices(Op, &success_order, model.calls.items);
    try std.testing.expect(!model.original and !model.tomb and !model.intent and model.completion);
    try std.testing.expect(owner.isPristine());
}

test "every mutation checkpoint resumes from durable model with a fresh owner" {
    inline for (.{
        Op.sync_parent_after_intent,
        Op.sync_parent_after_rename,
        Op.unlink_4,
        Op.sync_tomb,
        Op.unlink_3,
        Op.unlink_2,
        Op.unlink_1,
        Op.unlink_0,
        Op.remove_tomb,
        Op.sync_parent_after_tomb,
        Op.publish_completion,
        Op.sync_parent_after_completion,
        Op.remove_intent,
        Op.sync_parent_final,
    }) |checkpoint| {
        var model = Model{ .fail_once = checkpoint };
        defer model.deinit();
        var first: recovery.Recovery = .{};
        try std.testing.expectEqual(recovery.Outcome.cleanup_required, try recovery.testing_api.begin(&model, &first));
        try std.testing.expect(first.isPristine());
        var restarted: recovery.Recovery = .{};
        try std.testing.expectEqual(recovery.Outcome.success, try recovery.testing_api.recover(&model, &restarted));
        try std.testing.expect(restarted.isPristine());
        try std.testing.expect(!model.original and !model.tomb and !model.intent and model.completion);
    }
}

test "pre-intent failures never rename or unlink" {
    inline for (.{ Op.validate, Op.inspect_completion, Op.publish_intent }) |failure| {
        var model = Model{ .fail_once = failure };
        defer model.deinit();
        var owner: recovery.Recovery = .{};
        try std.testing.expectEqual(recovery.Outcome.audit_required, try recovery.testing_api.begin(&model, &owner));
        try std.testing.expect(model.original and !model.tomb and !model.intent and !model.completion);
        try std.testing.expect(std.mem.indexOfScalar(Op, model.calls.items, .rename) == null);
        try std.testing.expect(std.mem.indexOfScalar(Op, model.calls.items, .unlink_4) == null);
    }
}

test "completion receipt is idempotent and does not revisit tomb" {
    var model = Model{ .original = false, .present = @splat(false), .completion = true };
    defer model.deinit();
    var owner: recovery.Recovery = .{};
    try std.testing.expectEqual(recovery.Outcome.success, try recovery.testing_api.recover(&model, &owner));
    try std.testing.expectEqualSlices(Op, &.{ .inspect_completion, .sync_parent_final, .close }, model.calls.items);
}

test "foreign unexpected ambiguous and non-prefix inventories delete nothing" {
    inline for (0..4) |variant| {
        var model = Model{ .original = false, .tomb = true, .intent = true };
        defer model.deinit();
        switch (variant) {
            0 => model.foreign = 4,
            1 => model.unexpected = true,
            2 => model.original = true,
            3 => model.present = .{ true, false, true, true, true },
            else => unreachable,
        }
        var owner: recovery.Recovery = .{};
        try std.testing.expectEqual(recovery.Outcome.audit_required, try recovery.testing_api.recover(&model, &owner));
        try std.testing.expect(std.mem.indexOfScalar(Op, model.calls.items, .unlink_4) == null);
    }
}

test "malformed intent and close uncertainty never become success" {
    var malformed = Model{ .original = false, .tomb = true, .intent = true, .malformed_intent = true };
    defer malformed.deinit();
    var first: recovery.Recovery = .{};
    try std.testing.expectEqual(recovery.Outcome.audit_required, try recovery.testing_api.recover(&malformed, &first));

    var close_failure = Model{ .fail_once = .close };
    defer close_failure.deinit();
    var second: recovery.Recovery = .{};
    try std.testing.expectEqual(recovery.Outcome.descriptor_close_failed, try recovery.testing_api.begin(&close_failure, &second));
    try std.testing.expect(close_failure.completion);
}

test "production surface exposes only typed begin and derived-path resume" {
    recovery.assertProductionBoundary();
}

test "production begin rejects result storage aliased with aggregate authority" {
    const size = @max(@sizeOf(recovery.Recovery), @sizeOf(@import("release_adapter_candidate_aggregate_reopen").ReopenedAggregate));
    const alignment = @max(@alignOf(recovery.Recovery), @alignOf(@import("release_adapter_candidate_aggregate_reopen").ReopenedAggregate));
    var storage: [size]u8 align(alignment) = @splat(0);
    const aggregate: *@import("release_adapter_candidate_aggregate_reopen").ReopenedAggregate = @ptrCast(&storage);
    const owner: *recovery.Recovery = @ptrCast(&storage);
    var verified: @import("release_adapter_github_post_publish_attestation").VerifiedRelease = .{};
    try std.testing.expectError(error.InvalidOwner, recovery.begin(std.testing.allocator, aggregate, &verified, owner));
}
