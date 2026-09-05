//! Production owner for stage-3 candidate preparation and its durable commit point.

const std = @import("std");
const phase = @import("release_adapter_candidate_stage3_preparation_phase");
const prerequisite = @import("release_adapter_candidate_prerequisite_product");
const baseline = @import("release_adapter_candidate_baseline_preparation_product");
const candidate_manifest = @import("release_adapter_candidate_manifest");
const preparation_handoff = @import("release_adapter_candidate_preparation_handoff");
const files = @import("release_adapter_files");
const deadline_mod = @import("release_adapter_deadline");
const cli_authority = @import("release_adapter_github_cli_authority");

pub const Deadline = deadline_mod.Deadline;
pub const PinnedCli = prerequisite.PinnedCli;
pub const ZigToolchainAuthority = baseline.ZigToolchainAuthority;

pub const BaselineInputs = struct {
    workspace_root: [:0]const u8,
    app_paths: baseline.AppPaths,
    toolchain: *const ZigToolchainAuthority,
    source_directory_fd: std.c.fd_t,
};

pub const Inputs = struct {
    prerequisite: prerequisite.Inputs,
    baseline: BaselineInputs,
    manifest: [:0]const u8,
    durable_preparation: [:0]const u8,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: phase.Transaction = .{},
    deadline: Deadline = .{},
    prerequisite: prerequisite.Execution = .{},
    baseline: baseline.Execution = .{},
    manifest: files.PinnedReleaseFile = .{},
    durable: preparation_handoff.DurablePreparation = .{},
    evidence_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_root_len: usize = 0,
    manifest_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_root_len: usize = 0,
    inputs: ?Inputs = null,
    token: []const u8 = "",
    scratch: []u8 = &.{},
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }
    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.transaction.needsAudit() and !self.hasBorrowed();
    }
    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsCleanup() or self.hasBorrowed()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.retryCleanupWith(&steps, &self.transaction);
        self.* = .{};
    }
    pub fn retryAuditCleanup(self: *@This()) !void {
        if (!self.needsAudit() or self.transaction.localCleanupComplete()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.retryAuditCleanupWith(&steps, &self.transaction);
    }
    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and
            self.deadline.isPristineForComposition() and self.prerequisite.isPristineForComposition() and
            self.baseline.isPristineForComposition() and pristineManifest(&self.manifest) and
            self.durable.owner == null and self.durable.phase == .pristine and self.evidence_root_len == 0 and
            self.manifest_root_len == 0 and allZero(&self.evidence_root) and allZero(&self.manifest_root) and !self.hasBorrowed();
    }
    fn hasBorrowed(self: *const @This()) bool {
        return self.inputs != null or self.token.len != 0 or self.scratch.len != 0;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, token: []const u8, scratch: []u8, budget_ns: i128, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    if (budget_ns <= 0) return error.InvalidBudget;
    if (inputs.baseline.source_directory_fd < 0 or aliases(execution, inputs, token, scratch)) return error.InvalidOwner;
    try validatePaths(inputs);
    try deadline_mod.start(budget_ns, &execution.deadline);
    execution.owner = execution;
    execution.inputs = inputs;
    execution.token = token;
    execution.scratch = scratch;
    execution.io = io;
    execution.allocator = allocator;
    var steps = ConcreteSteps{ .execution = execution };
    const outcome = phase.executeWith(&steps, &execution.deadline, &execution.transaction);
    execution.inputs = null;
    execution.token = "";
    execution.scratch = &.{};
    outcome catch |err| {
        if (execution.transaction.isPristineForComposition()) execution.* = .{};
        return err;
    };
    execution.* = .{};
}

const ConcreteSteps = struct {
    execution: *Execution,
    fn input(self: *@This()) !Inputs {
        return self.execution.inputs orelse error.InvalidOwner;
    }
    pub fn validatePreflight(self: *@This(), transaction: *phase.Transaction, deadline: *Deadline) !void {
        if (self.execution.owner != self.execution or transaction != &self.execution.transaction or
            deadline != &self.execution.deadline or !transaction.isPristineForComposition()) return error.InvalidOwner;
    }
    pub fn validateAuthority(self: *@This(), deadline: *Deadline) !void {
        if (deadline != &self.execution.deadline or self.execution.owner != self.execution) return error.InvalidOwner;
        _ = try deadline.remaining();
        const value = try self.input();
        try validatePaths(value);
        try cli_authority.revalidate(self.execution.allocator, value.prerequisite.cli.path, value.prerequisite.cli.pinned);
        if (self.execution.prerequisite.ownsCompletePrerequisites()) {
            try validatePrerequisite(value, self.execution);
        }
        if (self.execution.baseline.ownsSuccessfulOutputs()) try validateBaseline(value, self.execution);
        if (self.execution.manifest.value() != null) _ = try self.execution.manifest.revalidate(value.manifest);
        if (self.execution.transaction.retained) {
            if (self.execution.durable.phase != .retained_closed) return error.AuthorityChanged;
        } else if (self.execution.durable.phase == .open) _ = try self.execution.durable.revalidate();
        _ = try deadline.remaining();
    }
    pub fn runPrerequisite(self: *@This(), deadline: *Deadline) !void {
        const value = try self.input();
        try prerequisite.runBorrowingDeadline(self.execution.io, self.execution.allocator, value.prerequisite, self.execution.token, self.execution.scratch, deadline, &self.execution.prerequisite);
    }
    pub fn prerequisiteNeedsAudit(self: *@This()) bool {
        return self.execution.prerequisite.needsAudit();
    }
    pub fn runBaseline(self: *@This(), deadline: *Deadline) !void {
        const value = try self.input();
        try baseline.runBorrowingDeadline(self.execution.io, self.execution.allocator, .{
            .context = value.prerequisite.context,
            .identity = &self.execution.prerequisite.identity,
            .files = &self.execution.prerequisite.files,
            .product = &self.execution.prerequisite.product,
            .product_paths = value.prerequisite.paths,
            .source = &self.execution.prerequisite.source,
            .app_paths = value.baseline.app_paths,
            .toolchain = value.baseline.toolchain,
            .source_directory_fd = value.baseline.source_directory_fd,
        }, value.baseline.workspace_root, deadline, &self.execution.baseline);
    }
    pub fn authorManifest(self: *@This(), deadline: *Deadline) !void {
        _ = try deadline.remaining();
        const value = try self.input();
        const workspace = try self.execution.baseline.workspace.value();
        try candidate_manifest.author(self.execution.allocator, value.prerequisite.context, &self.execution.prerequisite.identity, &self.execution.prerequisite.files, &self.execution.prerequisite.product, value.prerequisite.paths, &self.execution.prerequisite.source, &self.execution.prerequisite.compatibility, &self.execution.baseline.runner.evidence, .{ .dmg = value.prerequisite.paths.dmg, .frozen_executable = value.prerequisite.paths.frozen_executable, .evidence = workspace.evidence, .output = value.manifest }, null, &self.execution.manifest);
        _ = try deadline.remaining();
    }
    pub fn promoteDurable(self: *@This(), deadline: *Deadline) !void {
        _ = try deadline.remaining();
        const value = try self.input();
        const workspace = try self.execution.baseline.workspace.value();
        const evidence_root = try copyParent(workspace.evidence, &self.execution.evidence_root, &self.execution.evidence_root_len);
        const manifest_root = try copyParent(value.manifest, &self.execution.manifest_root, &self.execution.manifest_root_len);
        try preparation_handoff.promote(self.execution.allocator, .{
            .evidence = .{ .file = &self.execution.baseline.runner.evidence, .root = evidence_root, .path = workspace.evidence },
            .manifest = .{ .file = &self.execution.manifest, .root = manifest_root, .path = value.manifest },
        }, value.durable_preparation, &self.execution.durable);
        _ = try deadline.remaining();
    }
    pub fn fenceDurable(self: *@This(), deadline: *Deadline) !void {
        _ = try deadline.remaining();
        _ = try self.execution.durable.revalidate();
        _ = try deadline.remaining();
    }
    pub fn closeRetaining(self: *@This(), deadline: *Deadline) !void {
        _ = try deadline.remaining();
        try self.execution.durable.closeRetaining();
        _ = try deadline.remaining();
    }
    pub fn durableRetained(self: *@This()) bool {
        return self.execution.durable.phase == .retained_closed;
    }
    pub fn cleanupDurable(self: *@This()) !void {
        if (self.execution.durable.phase == .open or self.execution.durable.phase == .cleanup_required) try self.execution.durable.cleanup();
        if (self.execution.durable.phase != .pristine) return error.InvalidOwner;
    }
    pub fn cleanupManifest(self: *@This()) !void {
        if (self.execution.manifest.value() != null) try self.execution.manifest.deinit();
        if (!pristineManifest(&self.execution.manifest)) return error.InvalidOwner;
        @memset(&self.execution.evidence_root, 0);
        self.execution.evidence_root_len = 0;
        @memset(&self.execution.manifest_root, 0);
        self.execution.manifest_root_len = 0;
    }
    pub fn cleanupBaseline(self: *@This()) !void {
        if (self.execution.baseline.ownsSuccessfulOutputs()) return self.execution.baseline.cleanup();
        if (self.execution.baseline.transaction.needsCleanup()) return self.execution.baseline.retryCleanup();
        if (!self.execution.baseline.isPristineForComposition()) return error.DependencyLive;
    }
    pub fn cleanupPrerequisite(self: *@This()) !void {
        if (self.execution.prerequisite.ownsCompletePrerequisites()) return self.execution.prerequisite.cleanup();
        if (self.execution.prerequisite.transaction.needsCleanup()) return self.execution.prerequisite.retryCleanup();
        if (!self.execution.prerequisite.isPristineForComposition()) return error.DependencyLive;
    }
    pub fn cleanupDeadline(self: *@This()) !void {
        if (self.execution.deadline.owner != &self.execution.deadline) return error.InvalidOwner;
        try self.execution.deadline.deinit();
    }
};

fn copyParent(path: [:0]const u8, storage: *[std.fs.max_path_bytes:0]u8, len: *usize) ![:0]const u8 {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    if (parent.len == 0 or parent.len >= storage.len) return error.InvalidPath;
    @memset(storage, 0);
    @memcpy(storage[0..parent.len], parent);
    len.* = parent.len;
    return storage[0..parent.len :0];
}

fn validatePaths(value: Inputs) !void {
    const paths = [_][]const u8{
        value.prerequisite.paths.dmg,             value.prerequisite.paths.frozen_executable,
        value.prerequisite.paths.dmg_work,        value.prerequisite.bundles.dmg_bundle,
        value.prerequisite.bundles.frozen_bundle, value.baseline.workspace_root,
        value.baseline.app_paths.main_executable, value.baseline.app_paths.cli_executable,
        value.manifest,                           value.durable_preparation,
    };
    for (paths) |path| if (!canonicalAbsolute(path)) return error.InvalidPath;
    for (paths, 0..) |left, index| for (paths[index + 1 ..]) |right|
        if (sameOrDescendant(left, right) or sameOrDescendant(right, left)) return error.InvalidPath;
    if (value.prerequisite.context.tag.len < 2) return error.InvalidPath;
    var name_storage: [512]u8 = undefined;
    const expected = std.fmt.bufPrint(&name_storage, "Maru-{s}-session-host-release.json", .{value.prerequisite.context.tag[1..]}) catch return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(value.manifest), expected)) return error.InvalidPath;
}

fn aliases(execution: *Execution, value: Inputs, token: []const u8, scratch: []const u8) bool {
    const owner = std.mem.asBytes(execution);
    const values = [_][]const u8{
        std.mem.asBytes(value.prerequisite.cli.pinned), std.mem.asBytes(value.baseline.toolchain),
        value.prerequisite.context.repository.owner,    value.prerequisite.context.repository.name,
        value.prerequisite.context.tag,                 value.prerequisite.context.source_commit,
        value.prerequisite.context.build.workflow_ref,  value.prerequisite.test_uuid,
        value.prerequisite.paths.dmg,                   value.prerequisite.paths.frozen_executable,
        value.prerequisite.paths.dmg_work,              value.prerequisite.cli.path,
        value.prerequisite.bundles.dmg_bundle,          value.prerequisite.bundles.frozen_bundle,
        value.baseline.workspace_root,                  value.baseline.app_paths.main_executable,
        value.baseline.app_paths.cli_executable,        value.manifest,
        value.durable_preparation,                      token,
        scratch,
    };
    for (values) |bytes| if (overlaps(owner, bytes)) return true;
    for (values, 0..) |left, index| for (values[index + 1 ..]) |right| if (overlaps(left, right)) return true;
    return false;
}

fn validatePrerequisite(value: Inputs, execution: *Execution) !void {
    const current = &execution.prerequisite;
    if (!current.ownsCompletePrerequisites()) return error.AuthorityChanged;
    _ = try current.attestation.revalidate(.{ .dmg = value.prerequisite.paths.dmg, .frozen_executable = value.prerequisite.paths.frozen_executable });
    _ = current.draft.value() orelse return error.AuthorityChanged;
    _ = try current.files.revalidate(.{ .dmg = value.prerequisite.paths.dmg, .frozen_executable = value.prerequisite.paths.frozen_executable });
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
    var product_source = ProductSource{ .files = &execution.prerequisite.files, .product = &execution.prerequisite.product, .paths = value.prerequisite.paths };
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
        return .{ .frozen_sha256 = value.frozen_sha256, .designated_requirement_sha256 = signing.designated_requirement_sha256, .team_id = signing.team_id };
    }
};

fn sameOrDescendant(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or
        (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}

fn canonicalAbsolute(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len < 2 or path.len >= std.fs.max_path_bytes or
        path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn pristineManifest(value: *const files.PinnedReleaseFile) bool {
    return value.owner == null and value.fd < 0 and value.parent_fd < 0 and value.path_len == 0 and
        allZero(&value.path_sha256) and allZero(&value.sha256) and !value.executable;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
