//! Closed, side-effect-free mapping from live invocation ownership to GitHub Actions step syntax.

const std = @import("std");
const owner = @import("release_adapter_live_workflow_owner");

const step_ids = [_][]const u8{
    "session-host-candidate-pinning",
    "session-host-candidate-attestation",
    "session-host-draft-authoring",
    "session-host-authored-attestation",
    "session-host-aggregate-prepare",
    "session-host-aggregate-finalize",
    "session-host-publication",
    "session-host-aggregate-cleanup",
};

pub const Binding = struct {
    invocation: owner.Invocation,
    identity: owner.Identity,
    step_id: []const u8,
    predecessor: ?[]const u8,
    action_uses: ?[]const u8,

    pub fn actionUses(self: @This()) ?[]const u8 {
        return if (self.identity.kind == .action) self.action_uses else null;
    }

    pub fn commandName(self: @This()) ?[]const u8 {
        return if (self.identity.kind == .command) self.identity.name else null;
    }

    pub fn executionName(self: @This()) []const u8 {
        return self.actionUses() orelse self.identity.name;
    }
};

const bindings = buildBindings();

pub fn all() []const Binding {
    return &bindings;
}

fn buildBindings() [owner.inventory.len]Binding {
    var result: [owner.inventory.len]Binding = undefined;
    for (owner.inventory, 0..) |invocation, index| {
        const selected = owner.identity(invocation);
        result[index] = .{
            .invocation = invocation,
            .identity = selected,
            .step_id = step_ids[index],
            .predecessor = if (index == 0) null else step_ids[index - 1],
            .action_uses = actionUses(selected),
        };
    }
    return result;
}

fn actionUses(identity: owner.Identity) ?[]const u8 {
    if (identity.kind != .action) return null;
    return switch (identity.stage) {
        .candidate_attestation => "./.github/actions/session-host-release-attest",
        .authored_attestation => "./.github/actions/session-host-release-attest-authored",
        else => unreachable,
    };
}

comptime {
    if (step_ids.len != owner.inventory.len) @compileError("workflow step inventory drift");
    for (bindings, 0..) |item, index| {
        if (@intFromEnum(item.identity.stage) != index)
            @compileError("workflow binding stage order drift");
        if (item.action_uses) |uses| {
            if (!std.mem.startsWith(u8, uses, "./.github/actions/") or
                !std.mem.startsWith(u8, item.identity.name, uses[2..]) or
                !std.mem.eql(u8, item.identity.name[uses.len - 2 ..], "/action.yml"))
                @compileError("workflow action identity drift");
        }
    }
}
