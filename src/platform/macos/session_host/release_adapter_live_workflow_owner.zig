//! Single composition owner for the eight heterogeneous live release workflow invocations.

const std = @import("std");
const checkpoint = @import("release_adapter_live_workflow_checkpoint");
const context = @import("release_adapter_context");
const phase = @import("release_adapter_live_workflow_phase");
const candidate_inputs = @import("release_adapter_live_candidate_inputs");

pub const max_bootstrap_token_bytes = checkpoint.max_root_identity_token_bytes;

pub fn canonicalRootPath(path: []const u8) bool {
    if (path.len < 2 or path[0] != '/' or path.len >= std.fs.max_path_bytes or path[path.len - 1] == '/') return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or component.len > std.fs.max_name_bytes or
            std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..") or
            std.mem.indexOfScalar(u8, component, 0) != null) return false;
    }
    return true;
}

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

pub const Error = checkpoint.Error || error{
    ExecutorBusy,
    InvalidActionResult,
    InvalidExecutor,
    InvalidExternalAction,
    InvalidCandidate,
};

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

/// Opens the fixed checkpoint authority inside the fresh process that precedes one composite
/// action payload. Keeping this here preserves one production owner for checkpoint primitives.
pub fn admitActionProcess(
    allocator: std.mem.Allocator,
    root_path: [:0]const u8,
    root_identity: []const u8,
    workflow: context.Context,
    invocation: Invocation,
) Error!void {
    const selected = identity(invocation);
    if (selected.kind != .action) return error.InvalidExternalAction;
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, root_path, try checkpoint.decodeRootIdentity(root_identity));
    defer root.deinit() catch {};
    _ = try checkpoint.admit(allocator, &root, selected.stage, workflow);
}

/// Publishes only the two outcomes a GitHub action can prove. Command-specific cleanup and
/// pre-mutation results stay unavailable at this boundary.
pub fn commitActionProcess(
    allocator: std.mem.Allocator,
    root_path: [:0]const u8,
    root_identity: []const u8,
    workflow: context.Context,
    invocation: Invocation,
    result: phase.Result,
) Error!void {
    const selected = identity(invocation);
    if (selected.kind != .action) return error.InvalidExternalAction;
    if (result != .succeeded and result != .failed) return error.InvalidActionResult;
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, root_path, try checkpoint.decodeRootIdentity(root_identity));
    defer root.deinit() catch {};
    _ = try checkpoint.advance(allocator, &root, selected.stage, result, workflow);
}

/// Initializes or recovers the exact initial-only workflow root and returns its sealed identity.
/// The CLI owns only argv/environment framing; checkpoint mechanics remain in this owner graph.
pub fn bootstrapProcess(
    allocator: std.mem.Allocator,
    root_path: [:0]const u8,
    workflow: context.Context,
    token_storage: *[checkpoint.max_root_identity_token_bytes:0]u8,
) Error![:0]const u8 {
    var root: checkpoint.Root = .{};
    try checkpoint.openRoot(&root, root_path);
    defer root.deinit() catch {};
    const identity_value = try checkpoint.initializeOrRecoverInitial(allocator, &root, workflow);
    return checkpoint.encodeRootIdentity(token_storage, identity_value);
}

/// Validates one exact signed candidate graph and durably settles the product stage. The held
/// file descriptors intentionally end with this process; the following action pins them again.
pub fn candidateInputsProcess(
    allocator: std.mem.Allocator,
    root_path: [:0]const u8,
    root_identity: []const u8,
    workflow: context.Context,
    candidate_directory: [:0]const u8,
) Error!void {
    var root: checkpoint.Root = .{};
    try checkpoint.openRootExpected(&root, root_path, try checkpoint.decodeRootIdentity(root_identity));
    defer root.deinit() catch {};
    _ = try checkpoint.admit(allocator, &root, .candidate_pinning, workflow);
    candidate_inputs.validate(workflow, candidate_directory) catch {
        _ = try checkpoint.advance(allocator, &root, .candidate_pinning, .failed, workflow);
        return error.InvalidCandidate;
    };
    _ = try checkpoint.advance(allocator, &root, .candidate_pinning, .succeeded, workflow);
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
