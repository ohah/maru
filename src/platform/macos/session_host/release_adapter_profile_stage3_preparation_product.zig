//! Production upgrade-B manifest authoring and durable preparation owner.

const std = @import("std");
const builtin = @import("builtin");
const phase = @import("release_adapter_profile_stage3_preparation_phase");
const profile_execution = @import("release_adapter_profile_upgrade_execution");
const profile_endorsement = @import("release_adapter_profile_endorsement");
const manifest_input_mod = @import("release_adapter_profile_predecessor_manifest_input");
const candidate_manifest = @import("release_adapter_candidate_manifest");
const preparation_handoff = @import("release_adapter_candidate_preparation_handoff");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const compatibility_mod = @import("release_adapter_candidate_compatibility");
const source_tree = @import("release_adapter_github_source_tree");
const upgrade_workspace = @import("release_adapter_candidate_upgrade_workspace");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const deadline_mod = @import("release_adapter_deadline");

pub const Stage = phase.Stage;
pub const Transaction = phase.Transaction;
pub const Deadline = deadline_mod.Deadline;

pub const Inputs = struct {
    context: context_mod.Context,
    environment: profile_endorsement.Environment,
    profile: *const profile_endorsement.Owner,
    upgrade: *const profile_execution.ProfileUpgradeExecution,
    manifest_input: *const manifest_input_mod.ProfileManifestInput,
    candidate: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    candidate_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
    compatibility: *const compatibility_mod.CandidateCompatibility,
    workspace: *upgrade_workspace.Workspace,
    manifest: [:0]const u8,
    durable_preparation: [:0]const u8,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: Transaction = .{},
    deadline: Deadline = .{},
    manifest: files.PinnedReleaseFile = .{},
    durable: preparation_handoff.DurablePreparation = .{},
    evidence_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    evidence_root_len: usize = 0,
    manifest_root: [std.fs.max_path_bytes:0]u8 = @splat(0),
    manifest_root_len: usize = 0,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and
            self.deadline.isPristineForComposition() and pristineFile(&self.manifest) and
            self.durable.owner == null and self.durable.phase == .pristine and
            self.evidence_root_len == 0 and self.manifest_root_len == 0 and
            allZero(&self.evidence_root) and allZero(&self.manifest_root);
    }
    pub fn auditStage(self: *const @This()) Stage {
        return self.transaction.auditStage();
    }
    pub fn retainedCommit(self: *const @This()) bool {
        return self.transaction.retainedCommit();
    }
    pub fn localCleanupComplete(self: *const @This()) bool {
        return self.transaction.localCleanupComplete();
    }
    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsCleanup()) return error.InvalidOwner;
        var steps = Product{ .execution = self };
        try phase.retryCleanupWith(&steps, &self.deadline, &self.transaction);
        self.* = .{};
    }
    pub fn retryAuditCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsAudit()) return error.InvalidOwner;
        var steps = Product{ .execution = self };
        try phase.retryAuditCleanupWith(&steps, &self.deadline, &self.transaction);
    }
};

pub fn run(allocator: std.mem.Allocator, inputs: Inputs, budget_ns: i128, execution: *Execution) !void {
    if (!execution.isPristineForComposition() or aliases(execution, inputs)) return error.InvalidOwner;
    try validatePaths(inputs);
    var steps = Product{ .execution = execution, .inputs = inputs, .allocator = allocator };
    const outcome = runOwned(&steps, budget_ns, execution);
    outcome catch |err| {
        if (execution.transaction.isPristineForComposition()) execution.* = .{};
        return err;
    };
    execution.* = .{};
}

pub fn runWith(steps: anytype, budget_ns: i128, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("runWith is test-only");
    return runOwned(steps, budget_ns, execution);
}

pub fn retryAuditCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("retryAuditCleanupWith is test-only");
    return phase.retryAuditCleanupWith(steps, &execution.deadline, &execution.transaction);
}

pub fn retryCleanupWith(steps: anytype, execution: *Execution) !void {
    if (!builtin.is_test) @compileError("retryCleanupWith is test-only");
    return phase.retryCleanupWith(steps, &execution.deadline, &execution.transaction);
}

fn runOwned(steps: anytype, budget_ns: i128, execution: *Execution) !void {
    if (!execution.isPristineForComposition()) return error.InvalidOwner;
    try steps.startDeadline(budget_ns, &execution.deadline);
    execution.owner = execution;
    phase.executeWith(steps, &execution.deadline, &execution.transaction) catch |err| {
        if (execution.transaction.isPristineForComposition()) execution.* = .{};
        return err;
    };
    execution.* = .{};
}

const Product = struct {
    execution: *Execution,
    inputs: ?Inputs = null,
    allocator: std.mem.Allocator = undefined,

    fn input(self: *@This()) !Inputs {
        return self.inputs orelse error.InvalidOwner;
    }
    pub fn startDeadline(_: *@This(), budget_ns: i128, deadline: *Deadline) !void {
        try deadline_mod.start(budget_ns, deadline);
    }
    pub fn validatePreflight(self: *@This(), transaction: *Transaction, deadline: *Deadline) !void {
        if (self.execution.owner != self.execution or transaction != &self.execution.transaction or
            deadline != &self.execution.deadline or !transaction.isPristineForComposition()) return error.InvalidOwner;
        const value = try self.input();
        try validatePaths(value);
    }
    pub fn validateProfile(self: *@This(), deadline: *Deadline) !void {
        if (deadline != &self.execution.deadline or self.execution.owner != self.execution) return error.InvalidOwner;
        _ = try deadline.remaining();
        const value = try self.input();
        try revalidateProfile(self.allocator, value, deadline);
        if (self.execution.manifest.value() != null) _ = try self.execution.manifest.revalidate(value.manifest);
        if (self.execution.transaction.retained) {
            if (self.execution.durable.phase != .retained_closed) return error.AuthorityChanged;
        } else if (self.execution.durable.phase == .open) _ = try self.execution.durable.revalidate();
        _ = try deadline.remaining();
    }
    pub fn authorManifest(self: *@This(), deadline: *Deadline) !void {
        _ = try deadline.remaining();
        const value = try self.input();
        const profile = try profileView(self.allocator, value, deadline);
        try candidate_manifest.author(self.allocator, value.context, value.candidate, value.files, value.product, value.candidate_paths, value.source, value.compatibility, profile.evidence, .{
            .dmg = value.candidate_paths.dmg,
            .frozen_executable = value.candidate_paths.frozen_executable,
            .evidence = profile.evidence_path,
            .output = value.manifest,
        }, .{
            .identity = &value.upgrade.predecessor.identity,
            .authenticated = profile.manifest.authenticated,
            .held_manifest = profile.manifest.file,
            .assets = &value.upgrade.predecessor.assets,
        }, &self.execution.manifest);
        _ = try deadline.remaining();
    }
    pub fn promoteDurable(self: *@This(), deadline: *Deadline) !void {
        _ = try deadline.remaining();
        const value = try self.input();
        const profile = try profileView(self.allocator, value, deadline);
        const evidence_root = try copyParent(profile.evidence_path, &self.execution.evidence_root, &self.execution.evidence_root_len);
        const manifest_root = try copyParent(value.manifest, &self.execution.manifest_root, &self.execution.manifest_root_len);
        try preparation_handoff.promote(self.allocator, .{
            .evidence = .{ .file = profile.evidence, .root = evidence_root, .path = profile.evidence_path },
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
        if (self.execution.durable.phase == .open or self.execution.durable.phase == .cleanup_required)
            try self.execution.durable.cleanup();
        if (self.execution.durable.phase != .pristine) return error.InvalidOwner;
    }
    pub fn cleanupManifest(self: *@This()) !void {
        if (self.execution.manifest.value() != null) try self.execution.manifest.deinit();
        if (!pristineFile(&self.execution.manifest)) return error.InvalidOwner;
        @memset(&self.execution.evidence_root, 0);
        self.execution.evidence_root_len = 0;
        @memset(&self.execution.manifest_root, 0);
        self.execution.manifest_root_len = 0;
    }
    pub fn manifestStillLive(self: *@This()) bool {
        return !pristineFile(&self.execution.manifest);
    }
    pub fn cleanupDeadline(_: *@This(), deadline: *Deadline) !void {
        try deadline.deinit();
    }
    pub fn deadlineStillLive(_: *@This(), deadline: *Deadline) bool {
        return !deadline.isPristineForComposition();
    }
};

const ProfileView = struct {
    evidence: *const files.PinnedReleaseFile,
    evidence_path: [:0]const u8,
    manifest: manifest_input_mod.ProfileManifestInput.View,
};

fn profileView(allocator: std.mem.Allocator, value: Inputs, deadline: *Deadline) !ProfileView {
    try revalidateProfile(allocator, value, deadline);
    const workspace = try value.workspace.value();
    return .{
        .evidence = &value.upgrade.execution.evidence,
        .evidence_path = workspace.evidence,
        .manifest = value.manifest_input.view() orelse return error.AuthorityChanged,
    };
}

fn revalidateProfile(allocator: std.mem.Allocator, value: Inputs, deadline: *Deadline) !void {
    if (!value.upgrade.ownsSuccessfulOutputs()) return error.AuthorityChanged;
    const timing = value.upgrade.timing;
    if (!timing.success or timing.predecessor_auth_ns == 0 or timing.signed_one_ns == 0 or
        timing.signed_near_max_ns == 0 or timing.runner_phase_ns == 0 or timing.profile_phase_ns == 0) return error.InvalidTiming;
    const child_sum = std.math.add(u64, timing.signed_one_ns, timing.signed_near_max_ns) catch return error.InvalidTiming;
    const nested_sum = std.math.add(u64, timing.predecessor_auth_ns, timing.runner_phase_ns) catch return error.InvalidTiming;
    if (timing.runner_phase_ns < child_sum or timing.profile_phase_ns < nested_sum) return error.InvalidTiming;
    _ = try value.candidate.revalidate(value.context, value.files, value.product, value.candidate_paths, value.source);
    _ = try value.compatibility.revalidate(value.files, value.product, value.candidate_paths);
    const workspace = try value.workspace.value();
    _ = try value.upgrade.execution.evidence.revalidate(workspace.evidence);
    _ = value.manifest_input.view() orelse return error.AuthorityChanged;
    _ = try value.upgrade.predecessor.revalidate(
        allocator,
        value.context,
        value.environment,
        value.profile,
        value.manifest_input,
        deadline,
    );
}

fn validatePaths(value: Inputs) !void {
    const workspace = try value.workspace.value();
    const paths = [_][]const u8{ value.candidate_paths.dmg, value.candidate_paths.frozen_executable, value.candidate_paths.dmg_work, workspace.evidence, value.manifest, value.durable_preparation };
    for (paths) |path| if (!canonicalAbsolute(path)) return error.InvalidPath;
    for (paths, 0..) |left, index| for (paths[index + 1 ..]) |right|
        if (sameOrDescendant(left, right) or sameOrDescendant(right, left)) return error.InvalidPath;
}

fn aliases(execution: *Execution, value: Inputs) bool {
    const result = std.mem.asBytes(execution);
    const owners = [_][]const u8{ std.mem.asBytes(value.profile), std.mem.asBytes(value.upgrade), std.mem.asBytes(value.manifest_input), std.mem.asBytes(value.candidate), std.mem.asBytes(value.files), std.mem.asBytes(value.product), std.mem.asBytes(value.source), std.mem.asBytes(value.compatibility), std.mem.asBytes(value.workspace) };
    const borrowed = [_][]const u8{ owners[0], owners[1], owners[2], owners[3], owners[4], owners[5], owners[6], owners[7], owners[8], value.context.repository.owner, value.context.repository.name, value.context.tag, value.context.source_commit, value.context.build.workflow_ref, value.candidate_paths.dmg, value.candidate_paths.frozen_executable, value.candidate_paths.dmg_work, value.manifest, value.durable_preparation };
    for (borrowed) |bytes| if (overlaps(result, bytes)) return true;
    for (owners, 0..) |left, index| for (owners[index + 1 ..]) |right|
        if (overlaps(left, right)) return true;
    const environment_pointer = @intFromPtr(value.environment.context);
    for (borrowed) |bytes| {
        const start = @intFromPtr(bytes.ptr);
        const end = std.math.add(usize, start, bytes.len) catch return true;
        if (environment_pointer >= start and environment_pointer < end) return true;
    }
    const result_start = @intFromPtr(result.ptr);
    const result_end = std.math.add(usize, result_start, result.len) catch return true;
    if (environment_pointer >= result_start and environment_pointer < result_end) return true;
    return false;
}

fn copyParent(path: [:0]const u8, storage: *[std.fs.max_path_bytes:0]u8, len: *usize) ![:0]const u8 {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    if (parent.len == 0 or parent.len >= storage.len) return error.InvalidPath;
    @memset(storage, 0);
    @memcpy(storage[0..parent.len], parent);
    len.* = parent.len;
    return storage[0..parent.len :0];
}

fn canonicalAbsolute(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len < 2 or path.len >= std.fs.max_path_bytes or
        path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component|
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
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

fn pristineFile(value: *const files.PinnedReleaseFile) bool {
    return value.owner == null and value.fd < 0 and value.parent_fd < 0 and value.path_len == 0 and
        allZero(&value.path_sha256) and allZero(&value.sha256) and !value.executable;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}
