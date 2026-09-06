//! Single composition owner for the eight heterogeneous live release workflow invocations.

const std = @import("std");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");

pub const Kind = enum(u8) { product, action, command };

pub const Invocation = union(enum) {
    candidate_pinning: void,
    candidate_attestation: void,
    draft_authoring: void,
    authored_attestation: void,
    aggregate_prepare: void,
    aggregate_finalize: void,
    publication: void,
    aggregate_cleanup: void,
};

pub const inventory = [_]Invocation{
    .{ .candidate_pinning = {} },
    .{ .candidate_attestation = {} },
    .{ .draft_authoring = {} },
    .{ .authored_attestation = {} },
    .{ .aggregate_prepare = {} },
    .{ .aggregate_finalize = {} },
    .{ .publication = {} },
    .{ .aggregate_cleanup = {} },
};

pub const Identity = struct {
    stage: phase.Stage,
    kind: Kind,
    name: []const u8,
};

pub const Executor = struct {
    ctx: ?*anyopaque = null,
    call: ?*const fn (*anyopaque, Identity) phase.Result = null,
    owner: ?*Executor = null,
    active: bool = false,

    pub fn init(self: *@This(), ctx: *anyopaque, call: *const fn (*anyopaque, Identity) phase.Result) Error!void {
        if (self.owner != null or self.ctx != null or self.call != null or self.active)
            return error.InvalidExecutor;
        self.ctx = ctx;
        self.call = call;
        self.owner = self;
    }
};

pub const Error = checkpoint.Error || error{ InvalidExecutor, ExecutorBusy };

pub fn identity(invocation: Invocation) Identity {
    return switch (invocation) {
        .candidate_pinning => .{ .stage = .candidate_pinning, .kind = .product, .name = "signed-candidate-inputs" },
        .candidate_attestation => .{ .stage = .candidate_attestation, .kind = .action, .name = ".github/actions/session-host-release-live-candidate-attestation/action.yml" },
        .draft_authoring => .{ .stage = .draft_authoring, .kind = .command, .name = "prepare-candidate" },
        .authored_attestation => .{ .stage = .authored_attestation, .kind = .action, .name = ".github/actions/session-host-release-live-authored-attestation/action.yml" },
        .aggregate_prepare => .{ .stage = .aggregate_prepare, .kind = .command, .name = "prepare-candidate-aggregate" },
        .aggregate_finalize => .{ .stage = .aggregate_finalize, .kind = .command, .name = "finalize-candidate-aggregate" },
        .publication => .{ .stage = .publication, .kind = .command, .name = "resume-candidate-publication" },
        .aggregate_cleanup => .{ .stage = .aggregate_cleanup, .kind = .command, .name = "cleanup-candidate-aggregate" },
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    root: *checkpoint.Root,
    workflow: context.Context,
    invocation: Invocation,
    executor: *Executor,
) Error!phase.State {
    if (executor.owner != executor or executor.ctx == null or executor.call == null)
        return error.InvalidExecutor;
    if (executor.active) return error.ExecutorBusy;

    const selected = identity(invocation);
    const selected_ctx = executor.ctx.?;
    const selected_call = executor.call.?;
    _ = try checkpoint.admit(allocator, root, selected.stage, workflow);
    executor.active = true;
    defer executor.active = false;
    var call_context: CallContext = .{ .executor = executor, .identity = selected };
    const observed = try checkpoint.invoke(root, &call_context, execute);
    if (executor.owner != executor or executor.ctx != selected_ctx or executor.call == null or
        executor.call.? != selected_call or !executor.active)
        return error.InvalidExecutor;
    const result: phase.Result = if (observed == .failed_before_remote_mutation and selected.stage != .draft_authoring)
        .cleanup_failed
    else
        observed;
    return checkpoint.advance(allocator, root, selected.stage, result, workflow);
}

const CallContext = struct { executor: *Executor, identity: Identity };

fn execute(raw: *anyopaque) phase.Result {
    const call_context: *CallContext = @ptrCast(@alignCast(raw));
    return call_context.executor.call.?(call_context.executor.ctx.?, call_context.identity);
}

comptime {
    const fields = @typeInfo(Invocation).@"union".fields;
    if (fields.len != inventory.len) @compileError("live workflow invocation inventory drift");
    for (fields, 0..) |field, index| {
        const invocation = inventory[index];
        if (!std.mem.eql(u8, field.name, @tagName(invocation)))
            @compileError("live workflow invocation tag inventory drift");
        if (@intFromEnum(identity(invocation).stage) != index)
            @compileError("live workflow invocation order drift");
    }
}
