//! Concrete owner for one baseline-A candidate release.
//!
//! Workflow code supplies only initial authorities and storage. This owner derives every later
//! phase input from its own completed child owner, shares one deadline, and keeps the complete
//! graph when remote draft state makes automatic retry unsafe.

const std = @import("std");
const phase = @import("release_adapter_candidate_release_phase");
const prerequisite = @import("release_adapter_candidate_prerequisite_product");
const baseline = @import("release_adapter_candidate_baseline_preparation_product");
const publication = @import("release_adapter_candidate_publication_product");
const deadline_mod = @import("release_adapter_deadline");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const PinnedCli = prerequisite.PinnedCli;
pub const ZigToolchainAuthority = baseline.ZigToolchainAuthority;
pub const Deadline = deadline_mod.Deadline;

pub const BaselineInputs = struct {
    workspace_root: [:0]const u8,
    app_paths: baseline.AppPaths,
    toolchain: *const ZigToolchainAuthority,
    source_directory_fd: std.c.fd_t,
};

pub const PublicationInputs = struct {
    manifest: [:0]const u8,
};

pub const Inputs = struct {
    prerequisite: prerequisite.Inputs,
    baseline: BaselineInputs,
    publication: PublicationInputs,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: phase.Release = .{},
    deadline: Deadline = .{},
    prerequisite: prerequisite.Execution = .{},
    baseline: baseline.Execution = .{},
    publication: publication.Execution = .{},
    inputs: ?Inputs = null,
    token: []const u8 = "",
    scratch: []u8 = &.{},
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }

    pub fn ownsCompleteRelease(self: *const @This()) bool {
        return self.owner == self and self.transaction.ownsCompleteRelease() and
            self.deadline.isPristineForComposition() and self.prerequisite.ownsCompletePrerequisites() and
            self.baseline.ownsSuccessfulOutputs() and self.publication.ownsSuccessfulOutputs() and !self.hasBorrowed();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.transaction.needsAudit() and
            self.deadline.isPristineForComposition() and !self.hasBorrowed();
    }

    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsCompleteRelease()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.cleanupWith(&steps, &self.transaction);
        self.* = .{};
    }

    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsCleanup() or
            !self.deadline.isPristineForComposition() or self.hasBorrowed()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.retryCleanupWith(&steps, &self.transaction);
        self.* = .{};
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and
            self.deadline.isPristineForComposition() and self.prerequisite.isPristineForComposition() and
            self.baseline.isPristineForComposition() and self.publication.isPristineForComposition() and
            !self.hasBorrowed();
    }

    fn hasBorrowed(self: *const @This()) bool {
        return self.inputs != null or self.token.len != 0 or self.scratch.len != 0;
    }

    fn clearBorrowed(self: *@This()) void {
        self.inputs = null;
        self.token = "";
        self.scratch = &.{};
    }
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs_value: Inputs,
    token: []const u8,
    scratch: []u8,
    budget_ns: i128,
    execution: *Execution,
) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    if (budget_ns <= 0) return error.InvalidBudget;
    if (inputs_value.baseline.source_directory_fd < 0) return error.InvalidOwner;
    try validateAliases(inputs_value, token, scratch, execution);
    try validatePaths(inputs_value);

    try deadline_mod.start(budget_ns, &execution.deadline);
    execution.owner = execution;
    execution.inputs = inputs_value;
    execution.token = token;
    execution.scratch = scratch;
    execution.io = io;
    execution.allocator = allocator;

    var steps = ConcreteSteps{ .execution = execution };
    const outcome = phase.executeWith(&steps, &execution.deadline, &execution.transaction);
    execution.clearBorrowed();
    execution.deadline.deinit() catch return error.CleanupFailed;
    outcome catch |err| {
        if (execution.transaction.isPristineForComposition()) execution.* = .{};
        return err;
    };
}

const ConcreteSteps = struct {
    execution: *Execution,

    fn input(self: *@This()) !Inputs {
        return self.execution.inputs orelse error.InvalidOwner;
    }

    fn validateDeadline(self: *@This(), deadline: *Deadline) !void {
        if (deadline != &self.execution.deadline or deadline.owner != deadline) return error.InvalidOwner;
        _ = try deadline.remaining();
    }

    pub fn validatePreflight(self: *@This(), release: *phase.Release, deadline: *Deadline) !void {
        if (self.execution.owner != self.execution or release != &self.execution.transaction or
            deadline != &self.execution.deadline or !release.isPristineForComposition()) return error.InvalidOwner;
        try self.validateDeadline(deadline);
        const value = try self.input();
        try validateAliases(value, self.execution.token, self.execution.scratch, self.execution);
        try validatePaths(value);
        try prerequisiteCliRevalidate(self.execution.allocator, value);
        _ = try value.baseline.toolchain.revalidate();
    }

    pub fn validateAuthority(self: *@This(), deadline: *Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.input();
        try validateAliases(value, self.execution.token, self.execution.scratch, self.execution);
        try validatePaths(value);
        try prerequisiteCliRevalidate(self.execution.allocator, value);
        _ = try value.baseline.toolchain.revalidate();
        if (self.execution.transaction.prerequisite_attempted) try validatePrerequisite(value, self.execution);
        if (self.execution.transaction.baseline_attempted) try validateBaseline(value, self.execution);
        if (self.execution.transaction.publication_attempted) {
            if (!self.execution.publication.ownsSuccessfulOutputs()) return error.AuthorityChanged;
            try self.execution.publication.revalidateSuccessfulOutputs(
                self.execution.allocator,
                try publicationInputs(value, self.execution),
            );
        }
        try self.validateDeadline(deadline);
    }

    pub fn runPrerequisite(self: *@This(), deadline: *Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.input();
        try prerequisite.runBorrowingDeadline(
            self.execution.io,
            self.execution.allocator,
            value.prerequisite,
            self.execution.token,
            self.execution.scratch,
            deadline,
            &self.execution.prerequisite,
        );
    }

    pub fn prerequisiteNeedsCleanup(self: *const @This()) bool {
        return self.execution.prerequisite.transaction.needsCleanup();
    }

    pub fn prerequisiteNeedsAudit(self: *const @This()) bool {
        return self.execution.prerequisite.needsAudit();
    }

    pub fn prerequisiteIsPristine(self: *const @This()) bool {
        return self.execution.prerequisite.isPristineForComposition();
    }

    pub fn runBaseline(self: *@This(), deadline: *Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.input();
        try baseline.runBorrowingDeadline(
            self.execution.io,
            self.execution.allocator,
            baselineInputs(value, self.execution),
            value.baseline.workspace_root,
            deadline,
            &self.execution.baseline,
        );
    }

    pub fn runPublication(self: *@This(), deadline: *Deadline) !void {
        try self.validateDeadline(deadline);
        const value = try self.input();
        try publication.runBorrowingDeadline(
            self.execution.io,
            self.execution.allocator,
            try publicationInputs(value, self.execution),
            self.execution.token,
            self.execution.scratch,
            deadline,
            &self.execution.publication,
        );
    }

    pub fn cleanupPrerequisite(self: *@This()) !void {
        if (self.execution.prerequisite.ownsCompletePrerequisites()) return self.execution.prerequisite.cleanup();
        if (self.execution.prerequisite.transaction.needsCleanup()) return self.execution.prerequisite.retryCleanup();
        if (!self.execution.prerequisite.isPristineForComposition()) return error.InvalidOwner;
    }

    pub fn cleanupBaseline(self: *@This()) !void {
        if (self.execution.baseline.ownsSuccessfulOutputs()) return self.execution.baseline.cleanup();
        if (self.execution.baseline.transaction.needsCleanup()) return self.execution.baseline.retryCleanup();
        if (!self.execution.baseline.isPristineForComposition()) return error.InvalidOwner;
    }

    pub fn cleanupPublication(self: *@This()) !void {
        if (self.execution.publication.ownsSuccessfulOutputs()) return self.execution.publication.cleanup();
        if (self.execution.publication.transaction.needsCleanup()) return self.execution.publication.retryCleanup();
        if (!self.execution.publication.isPristineForComposition()) return error.InvalidOwner;
    }
};

fn baselineInputs(value: Inputs, execution: *Execution) baseline.Inputs {
    return .{
        .context = value.prerequisite.context,
        .identity = &execution.prerequisite.identity,
        .files = &execution.prerequisite.files,
        .product = &execution.prerequisite.product,
        .product_paths = value.prerequisite.paths,
        .source = &execution.prerequisite.source,
        .app_paths = value.baseline.app_paths,
        .toolchain = value.baseline.toolchain,
        .source_directory_fd = value.baseline.source_directory_fd,
    };
}

fn publicationInputs(value: Inputs, execution: *Execution) !publication.Inputs {
    const workspace = try execution.baseline.workspace.value();
    return .{
        .context = value.prerequisite.context,
        .identity = &execution.prerequisite.identity,
        .files = &execution.prerequisite.files,
        .product = &execution.prerequisite.product,
        .product_paths = value.prerequisite.paths,
        .source = &execution.prerequisite.source,
        .compatibility = &execution.prerequisite.compatibility,
        .evidence = &execution.baseline.runner.evidence,
        .draft = &execution.prerequisite.draft,
        .candidate_attestation = &execution.prerequisite.attestation,
        .cli = .{ .path = value.prerequisite.cli.path, .pinned = value.prerequisite.cli.pinned },
        .paths = .{
            .dmg = value.prerequisite.paths.dmg,
            .frozen_executable = value.prerequisite.paths.frozen_executable,
            .evidence = workspace.evidence,
            .manifest = value.publication.manifest,
        },
        .predecessor = null,
    };
}

fn validatePrerequisite(value: Inputs, execution: *Execution) !void {
    const current = &execution.prerequisite;
    if (!current.ownsCompletePrerequisites()) return error.AuthorityChanged;
    _ = try current.attestation.revalidate(.{
        .dmg = value.prerequisite.paths.dmg,
        .frozen_executable = value.prerequisite.paths.frozen_executable,
    });
    _ = current.draft.value() orelse return error.AuthorityChanged;
    _ = try current.files.revalidate(.{
        .dmg = value.prerequisite.paths.dmg,
        .frozen_executable = value.prerequisite.paths.frozen_executable,
    });
    _ = try current.product.revalidate(&current.files, value.prerequisite.paths);
    _ = current.source.value() orelse return error.AuthorityChanged;
    _ = try current.identity.revalidate(value.prerequisite.context, &current.files, &current.product, value.prerequisite.paths, &current.source);
    _ = try current.compatibility.revalidate(&current.files, &current.product, value.prerequisite.paths);
}

fn validateBaseline(value: Inputs, execution: *Execution) !void {
    const current = &execution.baseline;
    if (!current.ownsSuccessfulOutputs()) return error.AuthorityChanged;
    const workspace = try current.workspace.value();
    _ = try current.runner.evidence.revalidate(workspace.evidence);
    var product_source = ProductSource{
        .files = &execution.prerequisite.files,
        .product = &execution.prerequisite.product,
        .paths = value.prerequisite.paths,
    };
    _ = try current.app.revalidateWith(&product_source, value.baseline.app_paths);
    _ = try value.baseline.toolchain.revalidate();
}

const ProductSource = struct {
    files: *const prerequisite.CandidateFiles,
    product: *const prerequisite.CandidateProduct,
    paths: prerequisite.Paths,

    pub fn revalidate(self: *@This()) !baseline.AppProductView {
        const value = try self.product.revalidate(self.files, self.paths);
        const signing = value.apple.signing();
        return .{
            .frozen_sha256 = value.frozen_sha256,
            .designated_requirement_sha256 = signing.designated_requirement_sha256,
            .team_id = signing.team_id,
        };
    }
};

fn prerequisiteCliRevalidate(allocator: std.mem.Allocator, value: Inputs) !void {
    // The prerequisite product owns the concrete CLI type; its public authority is revalidated
    // here before every phase so later owners cannot silently substitute an executable.
    try cli_authority.revalidate(allocator, value.prerequisite.cli.path, value.prerequisite.cli.pinned);
}

fn validatePaths(value: Inputs) !void {
    const paths = [_][]const u8{
        value.prerequisite.paths.dmg,
        value.prerequisite.paths.frozen_executable,
        value.prerequisite.paths.dmg_work,
        value.baseline.workspace_root,
        value.baseline.app_paths.main_executable,
        value.baseline.app_paths.cli_executable,
        value.publication.manifest,
    };
    for (paths) |path| if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    for (paths, 0..) |left, index| for (paths[index + 1 ..]) |right| {
        if (sameOrDescendant(left, right) or sameOrDescendant(right, left)) return error.InvalidPath;
    };
    if (value.prerequisite.context.tag.len < 2) return error.InvalidPath;
    var name_storage: [512]u8 = undefined;
    const expected = std.fmt.bufPrint(&name_storage, "Maru-{s}-session-host-release.json", .{value.prerequisite.context.tag[1..]}) catch return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(value.publication.manifest), expected)) return error.InvalidPath;
}

fn validateAliases(value: Inputs, token: []const u8, scratch: []u8, execution: *Execution) !void {
    const owner = std.mem.asBytes(execution);
    const regions = [_][]const u8{
        std.mem.asBytes(value.prerequisite.cli.pinned), std.mem.asBytes(value.baseline.toolchain),
        value.prerequisite.context.repository.owner,    value.prerequisite.context.repository.name,
        value.prerequisite.context.tag,                 value.prerequisite.context.source_commit,
        value.prerequisite.context.build.workflow_ref,  value.prerequisite.test_uuid,
        value.prerequisite.paths.dmg,                   value.prerequisite.paths.frozen_executable,
        value.prerequisite.paths.dmg_work,              value.prerequisite.cli.path,
        value.baseline.workspace_root,                  value.baseline.app_paths.main_executable,
        value.baseline.app_paths.cli_executable,        value.publication.manifest,
        token,                                          scratch,
    };
    for (regions, 0..) |region, index| {
        if (overlaps(owner, region)) return error.InvalidOwner;
        for (regions[0..index]) |prior| if (overlaps(region, prior)) return error.InvalidOwner;
    }
}

fn sameOrDescendant(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or
        (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
