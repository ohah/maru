//! Locks the trusted Actions spelling of the eight live workflow invocations before release.yml
//! is allowed to consume paths, outputs, credentials, or reducer results.

const std = @import("std");
const binding = @import("release_adapter_live_workflow_binding");
const contract = @import("release_adapter_contract");
const owner = @import("release_adapter_live_workflow_owner");

const expected_steps = [_][]const u8{
    "session-host-candidate-pinning",
    "session-host-candidate-attestation",
    "session-host-draft-authoring",
    "session-host-authored-attestation",
    "session-host-aggregate-prepare",
    "session-host-aggregate-finalize",
    "session-host-publication",
    "session-host-aggregate-cleanup",
};

test "U5 live binding derives all eight ordered steps from the invocation owner" {
    const bindings = binding.all();
    try std.testing.expectEqual(@as(usize, 8), bindings.len);
    for (bindings, 0..) |item, index| {
        try std.testing.expectEqual(index, @intFromEnum(item.identity.stage));
        try std.testing.expectEqualStrings(expected_steps[index], item.step_id);
        try std.testing.expectEqual(owner.identity(item.invocation), item.identity);
        if (index == 0) {
            try std.testing.expect(item.predecessor == null);
        } else {
            try std.testing.expectEqualStrings(expected_steps[index - 1], item.predecessor.?);
        }
    }
}

test "U5 live binding keeps step and execution identities unique" {
    const bindings = binding.all();
    for (bindings, 0..) |left, left_index| {
        for (bindings[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(u8, left.step_id, right.step_id));
            try std.testing.expect(!std.mem.eql(u8, left.executionName(), right.executionName()));
        }
    }
}

test "U5 action bindings are canonical repository-local uses paths" {
    const bindings = binding.all();
    try std.testing.expectEqualStrings("./.github/actions/session-host-release-attest", bindings[1].actionUses().?);
    try std.testing.expectEqualStrings("./.github/actions/session-host-release-attest-authored", bindings[3].actionUses().?);
    for (bindings, 0..) |item, index| {
        if (index == 1 or index == 3) continue;
        try std.testing.expect(item.actionUses() == null);
    }
}

test "U5 command bindings are names recognized by the validator contract" {
    for (binding.all()) |item| {
        if (item.identity.kind != .command) continue;
        const parsed = contract.parseArgs(&.{item.commandName().?});
        try std.testing.expectError(error.MissingOption, parsed);
    }
}

test "U5 production binding inventory has one source owner" {
    const allocator = std.testing.allocator;
    const source = try std.fs.cwd().readFileAlloc(
        allocator,
        "src/platform/macos/session_host/release_adapter_live_workflow_binding.zig",
        128 * 1024,
    );
    defer allocator.free(source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "const step_ids ="));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "owner.inventory"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source, "phase.Stage"));
}
