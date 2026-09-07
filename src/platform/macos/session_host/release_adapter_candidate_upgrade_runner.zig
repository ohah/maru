//! Final-address production composition for one upgrade-B signed release run.

const std = @import("std");
const c = std.c;
const posix = std.posix;
const phase = @import("release_adapter_candidate_upgrade_phase");
const child = @import("release_adapter_candidate_upgrade_child");
const predecessor_copy = @import("release_adapter_candidate_upgrade_predecessor");
const evidence_mod = @import("release_adapter_candidate_upgrade_evidence");
const workspace_mod = @import("release_adapter_candidate_upgrade_workspace");
const deadline_mod = @import("release_adapter_deadline");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const predecessor_identity = @import("release_adapter_predecessor_evidence_identity");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const manifest_file = @import("release_adapter_github_manifest_file");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");
const zig_toolchain = @import("release_adapter_zig_toolchain_authority");
const manifest = @import("release_manifest");

pub const Workspace = workspace_mod.Workspace;
pub const CleanupKind = child.Kind;

pub const Inputs = struct {
    context: context_mod.Context,
    candidate: *const candidate_identity.CandidateEvidenceIdentity,
    files: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    candidate_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
    predecessor: *const predecessor_identity.PredecessorEvidenceIdentity,
    authenticated: *const authenticated_manifest.AuthenticatedManifest,
    held_manifest: *const manifest_file.ManifestFile,
    assets: *const predecessor_assets.AuthenticatedPredecessorAssets,
    workspace: *workspace_mod.Workspace,
    toolchain: *const zig_toolchain.ZigToolchainAuthority,
    source_directory_fd: c.fd_t,
};

pub const TimingDiagnostic = struct {
    success: bool = false,
    signed_one_ns: u64 = 0,
    signed_near_max_ns: u64 = 0,
    phase_ns: u64 = 0,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    predecessor: predecessor_copy.Materialized = .{},
    evidence: evidence_mod.PublishedEvidence = .{},
    deadline: deadline_mod.Deadline = .{},
    timing: TimingDiagnostic = .{},
    one_present: bool = false,
    near_max_present: bool = false,
    evidence_unlinked: bool = false,
    borrowed_deadline: bool = false,
    predecessor_source_fd: c.fd_t = -1,
    inputs: ?Inputs = null,
    cleanup_workspace: ?*workspace_mod.Workspace = null,
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        const deadline_valid = self.borrowed_deadline or self.deadline.owner == &self.deadline;
        return self.owner == self and self.inputs == null and self.cleanup_workspace != null and
            self.predecessor_source_fd < 0 and self.predecessor.owner == &self.predecessor and
            self.evidence.owner == &self.evidence and self.one_present and self.near_max_present and
            !self.evidence_unlinked and self.timing.success and deadline_valid;
    }

    pub fn needsCleanup(self: *const @This()) bool {
        return self.owner == self and !self.timing.success and hasArtifacts(self);
    }

    pub fn isPristineForComposition(self: *const @This()) bool {
        return pristineExecution(self);
    }

    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        try cleanupRetained(self);
        resetExecution(self);
        self.* = .{};
    }
};

pub fn timingForTest(one_ns: u64, near_max_ns: u64, phase_started: i128, phase_finished: i128) !TimingDiagnostic {
    if (one_ns == 0 or near_max_ns == 0 or phase_started < 0 or phase_finished <= phase_started)
        return error.InvalidTiming;
    const phase_i128 = phase_finished - phase_started;
    const phase_ns = std.math.cast(u64, phase_i128) orelse return error.InvalidTiming;
    const children = std.math.add(u64, one_ns, near_max_ns) catch return error.InvalidTiming;
    if (phase_ns < children) return error.InvalidTiming;
    return .{ .success = true, .signed_one_ns = one_ns, .signed_near_max_ns = near_max_ns, .phase_ns = phase_ns };
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, budget_ns: i128, result: *Execution) !void {
    try validatePristine(inputs, result);
    try deadline_mod.start(budget_ns, &result.deadline);
    result.owner = result;
    result.inputs = inputs;
    result.cleanup_workspace = inputs.workspace;
    result.io = io;
    result.allocator = allocator;
    var steps = Steps{ .io = io, .allocator = allocator, .inputs = inputs, .result = result, .deadline = &result.deadline };
    runSteps(&steps, result) catch |err| {
        result.inputs = null;
        return err;
    };
    result.inputs = null;
}

pub fn runBorrowingDeadline(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, deadline: *deadline_mod.Deadline, result: *Execution) !void {
    try validatePristine(inputs, result);
    _ = try deadline.remaining();
    if (rangesOverlap(std.mem.asBytes(deadline), std.mem.asBytes(result))) return error.InvalidOwner;
    result.owner = result;
    result.borrowed_deadline = true;
    result.inputs = inputs;
    result.cleanup_workspace = inputs.workspace;
    result.io = io;
    result.allocator = allocator;
    var steps = Steps{ .io = io, .allocator = allocator, .inputs = inputs, .result = result, .deadline = deadline };
    runSteps(&steps, result) catch |err| {
        result.inputs = null;
        return err;
    };
    result.inputs = null;
}

fn runSteps(steps: anytype, result: *Execution) !void {
    const started = monotonicNow() catch |err| {
        resetPristine(result);
        return err;
    };
    phase.runWith(steps) catch |err| {
        closePredecessorSource(result);
        result.inputs = null;
        result.timing = .{};
        if (!hasArtifacts(result)) resetPristine(result);
        return err;
    };
    closePredecessorSource(result);
    const finished = monotonicNow() catch |err| {
        cleanupArtifacts(steps) catch return error.CleanupFailed;
        resetPristine(result);
        return err;
    };
    result.timing = timingForTest(steps.one_ns, steps.near_max_ns, started, finished) catch |err| {
        cleanupArtifacts(steps) catch return error.CleanupFailed;
        resetPristine(result);
        return err;
    };
}

const Steps = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    result: *Execution,
    deadline: *deadline_mod.Deadline,
    one_ns: u64 = 0,
    near_max_ns: u64 = 0,

    pub fn startDeadline(self: *@This()) !*deadline_mod.Deadline {
        _ = try self.deadline.remaining();
        return self.deadline;
    }
    pub fn validateInitialAuthorities(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateAll(deadline);
    }
    pub fn materializePredecessor(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        if (self.result.predecessor_source_fd >= 0) return error.InvalidOwner;
        const assets = self.inputs.assets.value() orelse return error.InvalidOwner;
        self.result.predecessor_source_fd = try assets.downloads.openAssetDescriptor(.frozen_product_executable);
        var authority = PredecessorCopyAuthority{ .inputs = &self.inputs, .source_fd = self.result.predecessor_source_fd };
        try predecessor_copy.materialize(&authority, &self.result.predecessor);
    }
    pub fn runSignedOne(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.runChild(.one, deadline, &self.one_ns);
    }
    pub fn validateAuthoritiesAfterOne(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateAll(deadline);
    }
    pub fn runSignedNearMax(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.runChild(.near_max, deadline, &self.near_max_ns);
    }
    pub fn validateAuthoritiesAfterNearMax(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateAll(deadline);
    }
    pub fn publishEvidence(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        const paths = try self.inputs.workspace.value();
        try evidence_mod.publish(self.allocator, self.inputs.context, self.inputs.candidate, self.inputs.files, self.inputs.product, self.inputs.candidate_paths, self.inputs.source, self.inputs.predecessor, self.inputs.authenticated, self.inputs.held_manifest, self.inputs.assets, .{ .signed_upgrade_one = paths.signed_one_leaf, .signed_upgrade_near_max = paths.signed_near_max_leaf, .output = paths.evidence }, &self.result.evidence);
    }
    pub fn validateFinalAuthorities(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        try self.validateAll(deadline);
    }
    pub fn validateFinalDeadline(_: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
    }

    pub fn cleanupEvidence(self: *@This()) !void {
        try cleanupPinned(&self.result.evidence, &self.result.evidence_unlinked, self.inputs.workspace, (try self.inputs.workspace.value()).evidence);
    }
    pub fn cleanupNearMax(self: *@This()) !void {
        try cleanupChild(self.io, self.inputs.workspace, .near_max, &self.result.near_max_present);
    }
    pub fn cleanupOne(self: *@This()) !void {
        try cleanupChild(self.io, self.inputs.workspace, .one, &self.result.one_present);
    }
    pub fn cleanupPredecessor(self: *@This()) !void {
        if (self.result.predecessor.owner == &self.result.predecessor) try self.result.predecessor.cleanup();
    }

    fn runChild(self: *@This(), kind: child.Kind, deadline: *deadline_mod.Deadline, elapsed: *u64) !void {
        const started = try monotonicNow();
        switch (kind) {
            .one => self.result.one_present = true,
            .near_max => self.result.near_max_present = true,
        }
        var authority = ChildAuthority{ .inputs = &self.inputs, .materialized = &self.result.predecessor, .source_fd = self.result.predecessor_source_fd, .kind = kind };
        try child.run(self.io, &authority, self.inputs.toolchain, kind, self.inputs.source_directory_fd, deadline);
        const finished = try monotonicNow();
        const duration = finished - started;
        elapsed.* = std.math.cast(u64, duration) orelse return error.InvalidTiming;
        if (elapsed.* == 0) return error.InvalidTiming;
    }

    fn validateAll(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        _ = try deadline.remaining();
        _ = try self.inputs.candidate.revalidate(self.inputs.context, self.inputs.files, self.inputs.product, self.inputs.candidate_paths, self.inputs.source);
        _ = try self.inputs.predecessor.revalidate(self.inputs.authenticated, self.inputs.held_manifest, self.inputs.assets);
        _ = try self.inputs.workspace.value();
        _ = try self.inputs.toolchain.revalidate();
    }
};

const PredecessorCopyAuthority = struct {
    inputs: *const Inputs,
    source_fd: c.fd_t,
    pub fn revalidate(self: *@This()) !predecessor_copy.View {
        const identity = try self.inputs.predecessor.revalidate(self.inputs.authenticated, self.inputs.held_manifest, self.inputs.assets);
        const held = try self.inputs.assets.revalidateEvidence();
        var source = held.assets[0];
        for (held.assets) |asset| {
            if (asset.role == .frozen_product_executable) source = asset;
        }
        if (source.role != .frozen_product_executable or !std.mem.eql(u8, source.sha256, identity.executable_sha256)) return error.AuthorityChanged;
        if (self.source_fd < 0) return error.InvalidOwner;
        const paths = try self.inputs.workspace.value();
        return .{ .source_fd = self.source_fd, .source_size = source.size, .source_sha256 = source.sha256[0..64].*, .destination_dir_fd = try self.inputs.workspace.directoryDescriptor(), .destination_path = paths.predecessor_executable, .destination_leaf = "predecessor-executable" };
    }
};

const ChildAuthority = struct {
    inputs: *const Inputs,
    materialized: *const predecessor_copy.Materialized,
    source_fd: c.fd_t,
    kind: child.Kind,
    pub fn revalidate(self: *@This()) !child.View {
        const current = try self.inputs.candidate.revalidate(self.inputs.context, self.inputs.files, self.inputs.product, self.inputs.candidate_paths, self.inputs.source);
        const previous = try self.inputs.predecessor.revalidate(self.inputs.authenticated, self.inputs.held_manifest, self.inputs.assets);
        const paths = try self.inputs.workspace.value();
        var copy_authority = PredecessorCopyAuthority{ .inputs = self.inputs, .source_fd = self.source_fd };
        const executable = try self.materialized.revalidate(&copy_authority);
        if (!std.mem.eql(u8, &executable.sha256, previous.executable_sha256)) return error.AuthorityChanged;
        return .{
            .test_uuid = current.common.test_uuid,
            .predecessor_sha256 = previous.executable_sha256,
            .current_sha256 = current.common.candidate.executable_sha256,
            .designated_requirement_sha256 = current.designated_requirement_sha256,
            .predecessor_executable = executable.path,
            .current_executable = self.inputs.candidate_paths.frozen_executable,
            .home = if (self.kind == .one) paths.signed_one_home else paths.signed_near_max_home,
            .output = if (self.kind == .one) paths.signed_one_leaf else paths.signed_near_max_leaf,
            .kind = self.kind,
        };
    }
};

pub fn retryCleanup(result: *Execution) !void {
    if (!result.needsCleanup() or result.inputs != null) return error.InvalidOwner;
    try cleanupRetained(result);
    resetExecution(result);
    result.* = .{};
}

pub fn prepareWorkspaceForTest(workspace: *Workspace, root: [:0]const u8) !void {
    if (!@import("builtin").is_test) @compileError("prepareWorkspaceForTest is a test-only seam");
    try workspace_mod.prepare(workspace, root);
}

pub fn cleanupWorkspaceChildForTest(io: std.Io, workspace: *Workspace, kind: CleanupKind) !void {
    if (!@import("builtin").is_test) @compileError("cleanupWorkspaceChildForTest is a test-only seam");
    var attempted = true;
    try cleanupChild(io, workspace, kind, &attempted);
}

fn cleanupArtifacts(steps: anytype) !void {
    var failed = false;
    steps.cleanupEvidence() catch {
        failed = true;
    };
    steps.cleanupNearMax() catch {
        failed = true;
    };
    steps.cleanupOne() catch {
        failed = true;
    };
    steps.cleanupPredecessor() catch {
        failed = true;
    };
    if (failed) return error.CleanupFailed;
}

fn cleanupRetained(result: *Execution) !void {
    const workspace = result.cleanup_workspace orelse return error.InvalidOwner;
    var failed = false;
    cleanupPinned(&result.evidence, &result.evidence_unlinked, workspace, (workspace.value() catch return error.CleanupFailed).evidence) catch {
        failed = true;
    };
    cleanupChild(result.io, workspace, .near_max, &result.near_max_present) catch {
        failed = true;
    };
    cleanupChild(result.io, workspace, .one, &result.one_present) catch {
        failed = true;
    };
    if (result.predecessor.owner == &result.predecessor) result.predecessor.cleanup() catch {
        failed = true;
    };
    if (failed) return error.CleanupFailed;
}

fn cleanupPinned(value: *evidence_mod.PublishedEvidence, unlinked: *bool, workspace: *workspace_mod.Workspace, path: [:0]const u8) !void {
    if (value.owner == null) {
        if (unlinked.*) return error.CleanupFailed;
        return;
    }
    const root_fd = try workspace.directoryDescriptor();
    if (!unlinked.*) {
        const observed = try value.revalidate(path);
        var leaf_storage: [std.fs.max_name_bytes:0]u8 = undefined;
        const leaf = std.fmt.bufPrintZ(&leaf_storage, "{s}", .{std.fs.path.basename(path)}) catch return error.CleanupFailed;
        var named: posix.Stat = undefined;
        if (c.fstatat(root_fd, leaf.ptr, &named, posix.AT.SYMLINK_NOFOLLOW) != 0 or
            !posix.S.ISREG(named.mode) or named.dev != observed.identity.device or named.ino != observed.identity.inode)
            return error.CleanupFailed;
        if (c.unlinkat(root_fd, leaf.ptr, 0) != 0) return error.CleanupFailed;
        unlinked.* = true;
    }
    if (c.fsync(root_fd) != 0) return error.CleanupFailed;
    try value.deinit();
    unlinked.* = false;
}

fn cleanupChild(io: std.Io, workspace: *workspace_mod.Workspace, kind: child.Kind, present: *bool) !void {
    if (!present.*) return;
    const paths = try workspace.value();
    const leaf = if (kind == .one) paths.signed_one_leaf else paths.signed_near_max_leaf;
    const home = if (kind == .one) paths.signed_one_home else paths.signed_near_max_home;
    const root_fd = try workspace.directoryDescriptor();
    const leaf_name = std.fs.path.basename(leaf);
    var leaf_storage: [std.fs.max_name_bytes:0]u8 = undefined;
    const leaf_z = std.fmt.bufPrintZ(&leaf_storage, "{s}", .{leaf_name}) catch return error.CleanupFailed;
    if (c.unlinkat(root_fd, leaf_z.ptr, 0) != 0 and posix.errno(-1) != .NOENT) return error.CleanupFailed;
    (std.Io.Dir{ .handle = root_fd }).deleteTree(io, std.fs.path.basename(home)) catch return error.CleanupFailed;
    if (c.fsync(root_fd) != 0) return error.CleanupFailed;
    present.* = false;
}

fn validatePristine(inputs: Inputs, result: *const Execution) !void {
    if (!pristineExecution(result) or inputs.source_directory_fd < 0) return error.InvalidOwner;
    const bytes = std.mem.asBytes(result);
    inline for (.{
        std.mem.asBytes(inputs.candidate),        std.mem.asBytes(inputs.files),
        std.mem.asBytes(inputs.product),          std.mem.asBytes(inputs.source),
        std.mem.asBytes(inputs.predecessor),      std.mem.asBytes(inputs.authenticated),
        std.mem.asBytes(inputs.held_manifest),    std.mem.asBytes(inputs.assets),
        std.mem.asBytes(inputs.workspace),        std.mem.asBytes(inputs.toolchain),
        inputs.context.repository.owner,          inputs.context.repository.name,
        inputs.context.tag,                       inputs.context.source_commit,
        inputs.context.build.workflow_ref,        inputs.candidate_paths.dmg,
        inputs.candidate_paths.frozen_executable, inputs.candidate_paths.dmg_work,
    }) |other|
        if (rangesOverlap(bytes, other)) return error.InvalidOwner;
}

fn resetExecution(result: *Execution) void {
    if (!result.borrowed_deadline and result.deadline.owner == &result.deadline)
        result.deadline.deinit() catch {};
}

fn resetPristine(result: *Execution) void {
    resetExecution(result);
    result.* = .{};
}

fn closePredecessorSource(result: *Execution) void {
    if (result.predecessor_source_fd >= 0) {
        _ = c.close(result.predecessor_source_fd);
        result.predecessor_source_fd = -1;
    }
}

fn hasArtifacts(result: *const Execution) bool {
    return result.predecessor.owner == &result.predecessor or result.evidence.owner == &result.evidence or result.evidence_unlinked or
        result.one_present or result.near_max_present;
}

fn pristineExecution(result: *const Execution) bool {
    return result.owner == null and result.predecessor.owner == null and result.evidence.owner == null and
        result.deadline.owner == null and result.deadline.started_ns == 0 and result.deadline.expires_ns == 0 and
        !result.one_present and !result.near_max_present and !result.evidence_unlinked and !result.borrowed_deadline and
        !result.timing.success and result.timing.signed_one_ns == 0 and result.timing.signed_near_max_ns == 0 and
        result.timing.phase_ns == 0 and result.predecessor_source_fd < 0 and result.inputs == null and
        result.cleanup_workspace == null;
}

fn monotonicNow() !i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0) return error.ClockFailed;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

comptime {
    _ = manifest.AssetRole;
}
