//! Production composition owner for one baseline-A signed candidate run.
//!
//! All paths and identity scalars are derived from final-address authorities. A failed cleanup
//! keeps this execution at its original address with the exact product attempt set intact.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const product_execution = @import("release_adapter_candidate_baseline_product");
const child = @import("release_adapter_candidate_baseline_child");
const evidence_mod = @import("release_adapter_candidate_baseline_evidence");
const app_mod = @import("release_adapter_candidate_baseline_app");
const workspace_mod = @import("release_adapter_candidate_baseline_workspace");
const deadline_mod = @import("release_adapter_deadline");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const zig_toolchain = @import("release_adapter_zig_toolchain_authority");

pub const Workspace = workspace_mod.Workspace;
pub const CleanupKind = enum { default_false, signed_app_quit, evidence };

pub const Inputs = struct {
    context: context_mod.Context,
    identity: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    product_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
    app: *const app_mod.CandidateApp,
    app_paths: app_mod.Paths,
    workspace: *workspace_mod.Workspace,
    toolchain: *const zig_toolchain.ZigToolchainAuthority,
    source_directory_fd: c.fd_t,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    product_execution: product_execution.Execution = .{},
    deadline: deadline_mod.Deadline = .{},
    evidence: evidence_mod.PublishedEvidence = .{},
    inputs: ?Inputs = null,
    cleanup_workspace: ?*Workspace = null,
    borrowed_deadline: bool = false,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    budget_ns: i128 = 0,

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        const deadline_valid = self.borrowed_deadline or self.deadline.owner == &self.deadline;
        return self.owner == self and self.inputs == null and self.cleanup_workspace != null and deadline_valid and
            self.evidence.owner == &self.evidence and self.product_execution.ownsSuccessfulChildren();
    }
    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.product_execution.successful and (self.product_execution.needsCleanup() or
            self.deadline.owner == &self.deadline or self.evidence.owner == &self.evidence);
    }
    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }
    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        if (!cleanupArtifacts(&steps)) return error.CleanupFailed;
        cleanupDeadline(self) catch return error.CleanupFailed;
        self.* = .{};
    }
    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.product_execution.owner == null and self.deadline.owner == null and
            self.deadline.started_ns == 0 and self.deadline.expires_ns == 0 and
            self.evidence.owner == null and self.evidence.fd < 0 and self.evidence.parent_fd < 0 and self.inputs == null and
            self.cleanup_workspace == null and !self.borrowed_deadline;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, budget_ns: i128, execution: *Execution) !void {
    if (!execution.pristine() or inputs.source_directory_fd < 0 or budget_ns <= 0 or aliasesExecution(execution, inputs))
        return error.InvalidOwner;
    execution.owner = execution;
    execution.inputs = inputs;
    execution.cleanup_workspace = inputs.workspace;
    execution.io = io;
    execution.allocator = allocator;
    execution.budget_ns = budget_ns;
    var steps = ConcreteSteps{ .execution = execution };
    product_execution.executeWith(&steps, &execution.product_execution) catch |err| {
        execution.inputs = null;
        if (!execution.product_execution.needsCleanup()) {
            cleanupDeadline(execution) catch return error.CleanupFailed;
            execution.* = .{};
        }
        return err;
    };
    execution.inputs = null;
}

pub fn runBorrowingDeadline(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, deadline: *deadline_mod.Deadline, execution: *Execution) !void {
    if (!execution.pristine() or inputs.source_directory_fd < 0 or deadline.owner != deadline or
        aliasesExecution(execution, inputs) or overlaps(std.mem.asBytes(execution), std.mem.asBytes(deadline))) return error.InvalidOwner;
    _ = try deadline.remaining();
    execution.owner = execution;
    execution.inputs = inputs;
    execution.cleanup_workspace = inputs.workspace;
    execution.borrowed_deadline = true;
    execution.io = io;
    execution.allocator = allocator;
    var steps = ConcreteSteps{ .execution = execution, .borrowed = deadline };
    product_execution.executeWith(&steps, &execution.product_execution) catch |err| {
        execution.inputs = null;
        if (!execution.product_execution.needsCleanup()) execution.* = .{};
        return err;
    };
    execution.inputs = null;
    _ = try deadline.remaining();
}

pub fn retryCleanup(execution: *Execution) !void {
    if (!execution.needsCleanup()) return error.InvalidOwner;
    if (execution.product_execution.needsCleanup()) {
        var steps = ConcreteSteps{ .execution = execution };
        try product_execution.retryCleanupWith(&steps, &execution.product_execution);
    }
    try cleanupDeadline(execution);
    execution.* = .{};
}

pub fn executeWith(steps: anytype, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("executeWith is a test-only seam");
    if (!execution.pristine()) return error.InvalidOwner;
    execution.owner = execution;
    product_execution.executeWith(steps, &execution.product_execution) catch |err| {
        if (!execution.product_execution.needsCleanup()) execution.* = .{};
        return err;
    };
}

pub fn executeWithBorrowedDeadline(steps: anytype, deadline: anytype, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("executeWithBorrowedDeadline is a test-only seam");
    if (!execution.pristine()) return error.InvalidOwner;
    execution.owner = execution;
    execution.borrowed_deadline = true;
    var borrowed = BorrowedSteps(@TypeOf(steps), @TypeOf(deadline)){ .steps = steps, .deadline = deadline };
    product_execution.executeWith(&borrowed, &execution.product_execution) catch |err| {
        if (!execution.product_execution.needsCleanup()) execution.* = .{};
        return err;
    };
}

pub fn retryCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("retryCleanupWith is a test-only seam");
    if (!execution.needsCleanup()) return error.InvalidOwner;
    try product_execution.retryCleanupWith(steps, &execution.product_execution);
    execution.* = .{};
}

pub fn cleanupWith(steps: anytype, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("cleanupWith is a test-only seam");
    if (execution.owner != execution or !execution.product_execution.ownsSuccessfulChildren())
        return error.InvalidOwner;
    if (!cleanupArtifacts(steps)) return error.CleanupFailed;
    execution.* = .{};
}

fn cleanupArtifacts(steps: anytype) bool {
    var clean = true;
    steps.cleanupEvidence() catch {
        clean = false;
    };
    steps.cleanupSignedAppQuit() catch {
        clean = false;
    };
    steps.cleanupDefaultFalse() catch {
        clean = false;
    };
    return clean;
}

const ConcreteSteps = struct {
    execution: *Execution,
    borrowed: ?*deadline_mod.Deadline = null,
    fn inputs(self: *@This()) !Inputs {
        if (self.execution.owner != self.execution) return error.InvalidOwner;
        return self.execution.inputs orelse error.InvalidOwner;
    }
    pub fn bindCandidate(self: *@This()) !void {
        try self.validateAuthorities();
    }
    pub fn startDeadline(self: *@This()) !*deadline_mod.Deadline {
        if (self.borrowed) |deadline| {
            _ = try deadline.remaining();
            return deadline;
        }
        try deadline_mod.start(self.execution.budget_ns, &self.execution.deadline);
        return &self.execution.deadline;
    }
    pub fn validateInitialCandidate(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        try self.validateAuthorities();
    }
    pub fn runDefaultFalse(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.runChild(.default_false, deadline);
    }
    pub fn validateCandidateAfterDefault(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        try self.validateAuthorities();
    }
    pub fn runSignedAppQuit(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.runChild(.signed_app_quit, deadline);
    }
    pub fn validateCandidateAfterQuit(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        try self.validateAuthorities();
    }
    pub fn publishEvidence(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        const value = try self.inputs();
        const paths = try value.workspace.value();
        try evidence_mod.publish(self.execution.allocator, value.context, value.identity, value.files, value.product, value.product_paths, value.source, .{
            .default_false = paths.default_false_leaf,
            .signed_app_quit = paths.signed_app_quit_leaf,
            .output = paths.evidence,
        }, &self.execution.evidence);
    }
    pub fn validateFinalCandidate(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        try self.validateAuthorities();
    }
    pub fn validateFinalDeadline(_: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
    }
    pub fn cleanupEvidence(self: *@This()) !void {
        try self.cleanupOutput(.evidence);
    }
    pub fn cleanupSignedAppQuit(self: *@This()) !void {
        try self.cleanupOutput(.signed_app_quit);
    }
    pub fn cleanupDefaultFalse(self: *@This()) !void {
        try self.cleanupOutput(.default_false);
    }

    fn runChild(self: *@This(), kind: child.Kind, deadline: *deadline_mod.Deadline) !void {
        const value = try self.inputs();
        try child.run(self.execution.io, .{
            .context = value.context,
            .identity = value.identity,
            .files = value.files,
            .product = value.product,
            .product_paths = value.product_paths,
            .source = value.source,
            .app = value.app,
            .app_paths = value.app_paths,
            .workspace = value.workspace,
        }, value.toolchain, kind, value.source_directory_fd, deadline);
    }
    fn validateAuthorities(self: *@This()) !void {
        const value = try self.inputs();
        _ = try value.identity.revalidate(value.context, value.files, value.product, value.product_paths, value.source);
        var source = ProductSource{ .files = value.files, .product = value.product, .paths = value.product_paths };
        _ = try value.app.revalidateWith(&source, value.app_paths);
        _ = try value.workspace.value();
        _ = try value.toolchain.revalidate();
    }
    fn cleanupOutput(self: *@This(), kind: CleanupKind) !void {
        const workspace = self.execution.cleanup_workspace orelse return error.InvalidOwner;
        const paths = try workspace.value();
        const leaf = switch (kind) {
            .default_false => paths.default_false_leaf,
            .signed_app_quit => paths.signed_app_quit_leaf,
            .evidence => paths.evidence,
        };
        if (kind == .evidence and self.execution.evidence.owner == &self.execution.evidence) {
            _ = try self.execution.evidence.revalidate(leaf);
            try self.execution.evidence.deinit();
        }
        try cleanupWorkspaceChild(self.execution.io, workspace, kind, leaf, paths);
    }
};

fn BorrowedSteps(comptime Steps: type, comptime Deadline: type) type {
    return struct {
        steps: Steps,
        deadline: Deadline,
        pub fn bindCandidate(self: *@This()) !void {
            try self.steps.bindCandidate();
        }
        pub fn startDeadline(self: *@This()) !Deadline {
            return self.deadline;
        }
        pub fn validateInitialCandidate(self: *@This(), deadline: Deadline) !void {
            try self.steps.validateInitialCandidate(deadline);
        }
        pub fn runDefaultFalse(self: *@This(), deadline: Deadline) !void {
            try self.steps.runDefaultFalse(deadline);
        }
        pub fn validateCandidateAfterDefault(self: *@This(), deadline: Deadline) !void {
            try self.steps.validateCandidateAfterDefault(deadline);
        }
        pub fn runSignedAppQuit(self: *@This(), deadline: Deadline) !void {
            try self.steps.runSignedAppQuit(deadline);
        }
        pub fn validateCandidateAfterQuit(self: *@This(), deadline: Deadline) !void {
            try self.steps.validateCandidateAfterQuit(deadline);
        }
        pub fn publishEvidence(self: *@This(), deadline: Deadline) !void {
            try self.steps.publishEvidence(deadline);
        }
        pub fn validateFinalCandidate(self: *@This(), deadline: Deadline) !void {
            try self.steps.validateFinalCandidate(deadline);
        }
        pub fn validateFinalDeadline(self: *@This(), deadline: Deadline) !void {
            try self.steps.validateFinalDeadline(deadline);
        }
        pub fn cleanupEvidence(self: *@This()) !void {
            try self.steps.cleanupEvidence();
        }
        pub fn cleanupSignedAppQuit(self: *@This()) !void {
            try self.steps.cleanupSignedAppQuit();
        }
        pub fn cleanupDefaultFalse(self: *@This()) !void {
            try self.steps.cleanupDefaultFalse();
        }
    };
}

pub fn cleanupWorkspaceChildForTest(io: std.Io, workspace: *Workspace, kind: CleanupKind) !void {
    if (!builtin.is_test) @compileError("cleanupWorkspaceChildForTest is a test-only seam");
    const paths = try workspace.value();
    const leaf = switch (kind) {
        .default_false => paths.default_false_leaf,
        .signed_app_quit => paths.signed_app_quit_leaf,
        .evidence => paths.evidence,
    };
    try cleanupWorkspaceChild(io, workspace, kind, leaf, paths);
}

pub fn prepareWorkspaceForTest(workspace: *Workspace, root: [:0]const u8) !void {
    if (!builtin.is_test) @compileError("prepareWorkspaceForTest is a test-only seam");
    try workspace_mod.prepare(workspace, root);
}

fn cleanupWorkspaceChild(io: std.Io, workspace: *Workspace, kind: CleanupKind, leaf: [:0]const u8, paths: workspace_mod.Paths) !void {
    const root_fd = workspace.root.root_fd;
    if (root_fd < 0) return error.CleanupFailed;
    var name_storage: [std.fs.max_name_bytes:0]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_storage, "{s}", .{std.fs.path.basename(leaf)}) catch return error.CleanupFailed;
    if (c.unlinkat(root_fd, name.ptr, 0) != 0 and posix.errno(-1) != .NOENT) return error.CleanupFailed;
    if (kind != .evidence) {
        const home = if (kind == .default_false) paths.default_false_home else paths.signed_app_quit_home;
        (std.Io.Dir{ .handle = root_fd }).deleteTree(io, std.fs.path.basename(home)) catch return error.CleanupFailed;
    }
    if (c.fsync(root_fd) != 0) return error.CleanupFailed;
}

const ProductSource = struct {
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    paths: candidate_product.Paths,
    pub fn revalidate(self: *@This()) !app_mod.ProductView {
        const value = try self.product.revalidate(self.files, self.paths);
        const signing = value.apple.signing();
        return .{ .frozen_sha256 = value.frozen_sha256, .designated_requirement_sha256 = signing.designated_requirement_sha256, .team_id = signing.team_id };
    }
};

fn cleanupDeadline(execution: *Execution) !void {
    if (execution.deadline.owner == null) return;
    if (execution.deadline.owner != &execution.deadline) return error.InvalidOwner;
    try execution.deadline.deinit();
}

fn aliasesExecution(execution: *Execution, inputs: Inputs) bool {
    const bytes = std.mem.asBytes(execution);
    const values = [_][]const u8{
        std.mem.asBytes(inputs.identity),  std.mem.asBytes(inputs.files),          std.mem.asBytes(inputs.product),
        std.mem.asBytes(inputs.source),    std.mem.asBytes(inputs.app),            std.mem.asBytes(inputs.workspace),
        std.mem.asBytes(inputs.toolchain), inputs.context.repository.owner,        inputs.context.repository.name,
        inputs.context.tag,                inputs.context.source_commit,           inputs.context.build.workflow_ref,
        inputs.product_paths.dmg,          inputs.product_paths.frozen_executable, inputs.product_paths.dmg_work,
        inputs.app_paths.main_executable,  inputs.app_paths.cli_executable,
    };
    for (values) |value| if (overlaps(bytes, value)) return true;
    return false;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
