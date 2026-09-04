//! Production wiring for one complete baseline evidence preparation transaction.

const std = @import("std");
const preparation = @import("release_adapter_candidate_baseline_preparation");
const runner = @import("release_adapter_candidate_baseline_runner");
const workspace_mod = @import("release_adapter_candidate_baseline_workspace");
const app_mod = @import("release_adapter_candidate_baseline_app");
const deadline_mod = @import("release_adapter_deadline");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const zig_toolchain = @import("release_adapter_zig_toolchain_authority");

pub const Context = context_mod.Context;
pub const CandidateFiles = candidate_files.CandidateFiles;
pub const CandidateProduct = candidate_product.CandidateProduct;
pub const CandidateEvidenceIdentity = candidate_identity.CandidateEvidenceIdentity;
pub const SourceTreeAuthority = source_tree.SourceTreeAuthority;
pub const ZigToolchainAuthority = zig_toolchain.ZigToolchainAuthority;
pub const Deadline = deadline_mod.Deadline;

pub const Inputs = struct {
    context: Context,
    identity: *const CandidateEvidenceIdentity,
    files: *const CandidateFiles,
    product: *const CandidateProduct,
    product_paths: candidate_product.Paths,
    source: *const SourceTreeAuthority,
    app_paths: app_mod.Paths,
    toolchain: *const ZigToolchainAuthority,
    source_directory_fd: std.c.fd_t,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: preparation.Execution = .{},
    deadline: deadline_mod.Deadline = .{},
    workspace: workspace_mod.Workspace = .{},
    app: app_mod.CandidateApp = .{},
    runner: runner.Execution = .{},
    inputs: ?Inputs = null,
    workspace_root: ?[:0]const u8 = null,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    budget_ns: i128 = 0,
    active_deadline: ?*Deadline = null,
    owns_deadline: bool = false,

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        return self.owner == self and self.transaction.ownsSuccessfulOutputs() and
            self.deadline.isPristineForComposition() and self.workspace.owner == &self.workspace and
            self.app.owner == &self.app and self.runner.ownsSuccessfulOutputs() and !self.hasBorrowedInputs();
    }
    pub fn hasBorrowedInputs(self: *const @This()) bool {
        return self.inputs != null or self.workspace_root != null or self.active_deadline != null or self.owns_deadline;
    }
    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsCleanup() or self.hasBorrowedInputs()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        preparation.retryCleanupWith(&steps, &self.transaction) catch return error.CleanupFailed;
        self.* = .{};
    }
    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        preparation.cleanupWith(&steps, &self.transaction) catch return error.CleanupFailed;
        self.* = .{};
    }
    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and
            self.deadline.isPristineForComposition() and
            self.workspace.isPristineForComposition() and self.app.isPristineForComposition() and
            self.runner.isPristineForComposition() and !self.hasBorrowedInputs();
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, inputs_value: Inputs, workspace_root: [:0]const u8, budget_ns: i128, execution: *Execution) !void {
    if (!execution.pristine() or budget_ns <= 0 or inputs_value.source_directory_fd < 0 or
        aliases(execution, inputs_value, workspace_root, null)) return error.InvalidOwner;
    return runWithDeadline(io, allocator, inputs_value, workspace_root, null, true, budget_ns, execution);
}

pub fn runBorrowingDeadline(io: std.Io, allocator: std.mem.Allocator, inputs_value: Inputs, workspace_root: [:0]const u8, deadline: *Deadline, execution: *Execution) !void {
    if (!execution.pristine() or inputs_value.source_directory_fd < 0 or
        aliases(execution, inputs_value, workspace_root, deadline)) return error.InvalidOwner;
    _ = try deadline.remaining();
    return runWithDeadline(io, allocator, inputs_value, workspace_root, deadline, false, 0, execution);
}

fn runWithDeadline(io: std.Io, allocator: std.mem.Allocator, inputs_value: Inputs, workspace_root: [:0]const u8, deadline: ?*Deadline, owns_deadline: bool, budget_ns: i128, execution: *Execution) !void {
    execution.owner = execution;
    execution.inputs = inputs_value;
    execution.workspace_root = workspace_root;
    execution.io = io;
    execution.allocator = allocator;
    execution.budget_ns = budget_ns;
    execution.active_deadline = deadline;
    execution.owns_deadline = owns_deadline;
    var steps = ConcreteSteps{ .execution = execution };
    preparation.executeWith(&steps, &execution.transaction) catch |err| {
        execution.inputs = null;
        execution.workspace_root = null;
        execution.active_deadline = null;
        execution.owns_deadline = false;
        if (!execution.transaction.needsCleanup()) execution.* = .{};
        return err;
    };
    execution.inputs = null;
    execution.workspace_root = null;
    execution.active_deadline = null;
    execution.owns_deadline = false;
}

pub fn prepareWorkspaceForTest(workspace: *workspace_mod.Workspace, root: [:0]const u8) !void {
    if (!@import("builtin").is_test) @compileError("prepareWorkspaceForTest is a test-only seam");
    try workspace_mod.prepare(workspace, root);
}

const ConcreteSteps = struct {
    execution: *Execution,
    fn validateDeadline(self: *@This(), deadline: *Deadline) !void {
        const expected = if (self.execution.owns_deadline) &self.execution.deadline else self.execution.active_deadline orelse return error.InvalidOwner;
        if (deadline != expected) return error.InvalidOwner;
        _ = try deadline.remaining();
    }
    fn inputs(self: *@This()) !Inputs {
        return self.execution.inputs orelse error.InvalidOwner;
    }
    pub fn validatePreflight(self: *@This(), transaction: *preparation.Execution) !void {
        if (self.execution.owner != self.execution or transaction != &self.execution.transaction) return error.InvalidOwner;
    }
    pub fn startDeadline(self: *@This()) !*deadline_mod.Deadline {
        if (self.execution.owns_deadline) {
            try deadline_mod.start(self.execution.budget_ns, &self.execution.deadline);
            return &self.execution.deadline;
        }
        const deadline = self.execution.active_deadline orelse return error.InvalidOwner;
        _ = try deadline.remaining();
        return deadline;
    }
    pub fn prepareWorkspace(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateDeadline(deadline);
        try workspace_mod.prepare(&self.execution.workspace, self.execution.workspace_root orelse return error.InvalidOwner);
    }
    pub fn bindCandidateApp(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.inputs();
        try app_mod.bindCandidateUntil(self.execution.io, value.files, value.product, value.product_paths, value.app_paths, deadline, &self.execution.app);
    }
    pub fn runBaseline(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.inputs();
        try runner.runBorrowingDeadline(self.execution.io, self.execution.allocator, .{
            .context = value.context,
            .identity = value.identity,
            .files = value.files,
            .product = value.product,
            .product_paths = value.product_paths,
            .source = value.source,
            .app = &self.execution.app,
            .app_paths = value.app_paths,
            .workspace = &self.execution.workspace,
            .toolchain = value.toolchain,
            .source_directory_fd = value.source_directory_fd,
        }, deadline, &self.execution.runner);
    }
    pub fn validateFinalCandidate(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.inputs();
        _ = try value.identity.revalidate(value.context, value.files, value.product, value.product_paths, value.source);
        var product_source = ProductSource{ .files = value.files, .product = value.product, .paths = value.product_paths };
        _ = try self.execution.app.revalidateWith(&product_source, value.app_paths);
        _ = try self.execution.workspace.value();
        _ = try value.toolchain.revalidate();
    }
    pub fn validateFinalDeadline(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateDeadline(deadline);
    }
    pub fn cleanupRunner(self: *@This()) !void {
        if (self.execution.runner.ownsSuccessfulOutputs()) return self.execution.runner.cleanup();
        if (self.execution.runner.needsCleanup()) return runner.retryCleanup(&self.execution.runner);
    }
    pub fn cleanupApp(self: *@This()) !void {
        if (self.execution.app.owner == &self.execution.app) try self.execution.app.deinit();
    }
    pub fn cleanupWorkspace(self: *@This()) !void {
        if (self.execution.runner.needsCleanup()) return error.DependencyLive;
        if (self.execution.workspace.owner == &self.execution.workspace) try self.execution.workspace.cleanup();
    }
    pub fn cleanupDeadline(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        if (self.execution.owns_deadline) {
            if (deadline != &self.execution.deadline or deadline.owner != deadline) return error.InvalidOwner;
            try deadline.deinit();
            return;
        }
        // A borrowed deadline is never a local cleanup capability. Operational fences above own
        // identity/freshness; unwind must still finish if an adversarial callback corrupts it.
    }
    pub fn retryCleanupDeadline(self: *@This()) !void {
        if (self.execution.deadline.owner != &self.execution.deadline) return error.InvalidOwner;
        try self.execution.deadline.deinit();
    }
};

const ProductSource = struct {
    files: *const CandidateFiles,
    product: *const CandidateProduct,
    paths: candidate_product.Paths,
    pub fn revalidate(self: *@This()) !app_mod.ProductView {
        const value = try self.product.revalidate(self.files, self.paths);
        const signing = value.apple.signing();
        return .{ .frozen_sha256 = value.frozen_sha256, .designated_requirement_sha256 = signing.designated_requirement_sha256, .team_id = signing.team_id };
    }
};

fn aliases(execution: *Execution, inputs_value: Inputs, workspace_root: []const u8, deadline: ?*Deadline) bool {
    const objects = [_][]const u8{
        std.mem.asBytes(execution),            std.mem.asBytes(inputs_value.identity),  std.mem.asBytes(inputs_value.files),
        std.mem.asBytes(inputs_value.product), std.mem.asBytes(inputs_value.source),    std.mem.asBytes(inputs_value.toolchain),
        inputs_value.context.repository.owner, inputs_value.context.repository.name,    inputs_value.context.tag,
        inputs_value.context.source_commit,    inputs_value.context.build.workflow_ref,
    };
    const paths = [_][]const u8{
        workspace_root,                      inputs_value.product_paths.dmg,         inputs_value.product_paths.frozen_executable,
        inputs_value.product_paths.dmg_work, inputs_value.app_paths.main_executable, inputs_value.app_paths.cli_executable,
    };
    for (objects, 0..) |left, index| {
        for (objects[index + 1 ..]) |right| if (overlaps(left, right)) return true;
        for (paths) |path| if (overlaps(left, path)) return true;
    }
    for (paths, 0..) |left, index| for (paths[index + 1 ..]) |right| if (overlaps(left, right)) return true;
    if (deadline) |value| {
        const bytes = std.mem.asBytes(value);
        for (objects) |object| if (overlaps(bytes, object)) return true;
        for (paths) |path| if (overlaps(bytes, path)) return true;
    }
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
