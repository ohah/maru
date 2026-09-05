//! Production owner for preparing every typed authority consumed by candidate publication.
//!
//! The generic transaction owns order and failure states. This boundary owns concrete storage,
//! validates every caller borrow before the first leaf, and re-derives the typed graph at every
//! fence so workflow shell cannot assemble or replay partial release authority.

const std = @import("std");
const phase = @import("release_adapter_candidate_prerequisite_phase");
const deadline_mod = @import("release_adapter_deadline");
const context_mod = @import("release_adapter_context");
const candidate_attestation = @import("release_adapter_candidate_attestation");
const draft_creation = @import("release_adapter_github_draft_creation");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const source_tree = @import("release_adapter_github_source_tree");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const compatibility_mod = @import("release_adapter_candidate_compatibility");
const cli_authority = @import("release_adapter_github_cli_authority");
const apple_transport = @import("release_adapter_apple_transport");
const scalar_identity = @import("release_adapter_identity");
const release_evidence = @import("release_evidence");

pub const Context = context_mod.Context;
pub const PinnedCli = cli_authority.PinnedExecutable;
pub const CandidateAttestation = candidate_attestation.CandidateAttestation;
pub const DraftAuthority = draft_creation.DraftAuthority;
pub const CandidateFiles = candidate_files.CandidateFiles;
pub const CandidateProduct = candidate_product.CandidateProduct;
pub const SourceTreeAuthority = source_tree.SourceTreeAuthority;
pub const CandidateEvidenceIdentity = candidate_identity.CandidateEvidenceIdentity;
pub const CandidateCompatibility = compatibility_mod.CandidateCompatibility;
pub const Deadline = deadline_mod.Deadline;

pub const Paths = candidate_product.Paths;
pub const Cli = struct { path: [:0]const u8, pinned: *const PinnedCli };
pub const Inputs = struct {
    context: Context,
    test_uuid: []const u8,
    paths: Paths,
    bundles: candidate_attestation.BundlePaths,
    cli: Cli,
};

const max_scratch_bytes: usize = 64 * 1024;
const max_token_bytes: usize = 4 * 1024;

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: phase.Preparation = .{},
    deadline: deadline_mod.Deadline = .{},
    attestation: CandidateAttestation = .{},
    draft: DraftAuthority = .{},
    files: CandidateFiles = .{},
    product: CandidateProduct = .{},
    source: SourceTreeAuthority = .{},
    identity: CandidateEvidenceIdentity = .{},
    compatibility: CandidateCompatibility = .{},
    apple_storage: apple_transport.Storage = undefined,
    inputs: ?Inputs = null,
    token: []const u8 = "",
    scratch: []u8 = &.{},
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    active_deadline: ?*Deadline = null,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }

    pub fn ownsCompletePrerequisites(self: *const @This()) bool {
        return self.owner == self and self.transaction.ownsCompletePrerequisites() and
            self.deadline.isPristineForComposition() and self.attestation.owner == &self.attestation and
            self.draft.owner == &self.draft and self.files.owner == &self.files and
            self.product.owner == &self.product and self.source.owner == &self.source and
            self.identity.owner == &self.identity and self.compatibility.owner == &self.compatibility and
            !self.hasBorrowed();
    }

    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.transaction.needsAudit() and self.deadline.isPristineForComposition() and
            !self.hasBorrowed();
    }

    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsCompletePrerequisites()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.cleanupWith(&steps, &self.transaction);
        self.* = .{};
    }

    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsCleanup() or !self.deadline.isPristineForComposition() or self.hasBorrowed())
            return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.retryCleanupWith(&steps, &self.transaction);
        self.* = .{};
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and
            self.deadline.isPristineForComposition() and
            pristineAttestation(&self.attestation) and pristineDraft(&self.draft) and
            pristineFiles(&self.files) and pristineProduct(&self.product) and pristineSource(&self.source) and
            pristineIdentity(&self.identity) and pristineCompatibility(&self.compatibility) and !self.hasBorrowed();
    }

    fn hasBorrowed(self: *const @This()) bool {
        return self.inputs != null or self.token.len != 0 or self.scratch.len != 0 or self.active_deadline != null;
    }

    fn clearBorrowed(self: *@This()) void {
        self.inputs = null;
        self.token = "";
        self.scratch = &.{};
        self.active_deadline = null;
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
    try validateAliases(inputs_value, token, scratch, execution, null);
    try validateStatic(inputs_value, token, scratch);

    try deadline_mod.start(budget_ns, &execution.deadline);
    return runWithDeadline(io, allocator, inputs_value, token, scratch, &execution.deadline, true, execution);
}

pub fn runBorrowingDeadline(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs_value: Inputs,
    token: []const u8,
    scratch: []u8,
    deadline: *Deadline,
    execution: *Execution,
) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    try validateAliases(inputs_value, token, scratch, execution, deadline);
    try validateStatic(inputs_value, token, scratch);
    _ = try deadline.remaining();
    return runWithDeadline(io, allocator, inputs_value, token, scratch, deadline, false, execution);
}

fn runWithDeadline(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs_value: Inputs,
    token: []const u8,
    scratch: []u8,
    deadline: *Deadline,
    owns_deadline: bool,
    execution: *Execution,
) !void {
    execution.owner = execution;
    execution.inputs = inputs_value;
    execution.token = token;
    execution.scratch = scratch;
    execution.io = io;
    execution.allocator = allocator;
    execution.active_deadline = deadline;

    var steps = ConcreteSteps{ .execution = execution };
    const outcome = phase.executeWith(&steps, deadline, &execution.transaction);
    execution.clearBorrowed();
    if (owns_deadline) execution.deadline.deinit() catch return error.CleanupFailed;
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

    pub fn validatePreflight(self: *@This(), preparation: *phase.Preparation, deadline: *deadline_mod.Deadline) !void {
        if (self.execution.owner != self.execution or preparation != &self.execution.transaction or
            deadline != self.execution.active_deadline or !preparation.isPristineForComposition()) return error.InvalidOwner;
        _ = try self.input();
    }

    pub fn validateAuthority(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        if (deadline != self.execution.active_deadline or self.execution.owner != self.execution) return error.InvalidOwner;
        _ = try deadline.remaining();
        const i = try self.input();
        try validateStatic(i, self.execution.token, self.execution.scratch);
        try cli_authority.revalidate(self.execution.allocator, i.cli.path, i.cli.pinned);
        const attempted = &self.execution.transaction;
        if (attempted.attestation_attempted) try validateAttestation(i, &self.execution.attestation);
        if (attempted.draft_attempted) try validateDraft(i, &self.execution.draft);
        if (attempted.files_attempted) try validateFiles(i, self.execution);
        if (attempted.product_attempted) try validateProduct(i, self.execution);
        if (attempted.source_attempted) try validateSource(i, &self.execution.source);
        if (attempted.identity_attempted) _ = try self.execution.identity.revalidate(i.context, &self.execution.files, &self.execution.product, i.paths, &self.execution.source);
        if (attempted.compatibility_attempted) _ = try self.execution.compatibility.revalidate(&self.execution.files, &self.execution.product, i.paths);
        _ = try deadline.remaining();
    }

    pub fn attestCandidate(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try candidate_attestation.composeBundlesUntil(self.execution.io, self.execution.allocator, i.context, filePaths(i.paths), i.bundles, .{ .path = i.cli.path, .pinned = i.cli.pinned }, self.execution.scratch, deadline, &self.execution.attestation);
    }

    pub fn createDraft(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try draft_creation.create(self.execution.io, self.execution.allocator, i.context, .{ .path = i.cli.path, .pinned = i.cli.pinned }, self.execution.token, self.execution.scratch, deadline, &self.execution.draft);
    }

    pub fn draftRequiresAudit(self: *const @This()) bool {
        return self.execution.draft.state() != .empty;
    }

    pub fn bindFiles(self: *@This(), _: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try candidate_files.observe(i.context, &self.execution.draft, &self.execution.attestation, filePaths(i.paths), &self.execution.files);
    }

    pub fn observeProduct(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try candidate_product.observe(self.execution.allocator, self.execution.io, &self.execution.files, i.paths, &self.execution.apple_storage, deadline, &self.execution.product);
    }

    pub fn observeSource(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try source_tree.observe(self.execution.io, self.execution.allocator, i.context, .{ .path = i.cli.path, .pinned = i.cli.pinned }, self.execution.token, self.execution.scratch, deadline, &self.execution.source);
    }

    pub fn composeIdentity(self: *@This(), _: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try candidate_identity.compose(i.context, i.test_uuid, &self.execution.files, &self.execution.product, i.paths, &self.execution.source, &self.execution.identity);
    }

    pub fn probeCompatibility(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try compatibility_mod.composeUntil(self.execution.io, &self.execution.files, &self.execution.product, i.paths, self.execution.scratch, deadline, &self.execution.compatibility);
    }

    pub fn cleanupAttestation(self: *@This()) !void {
        if (self.execution.attestation.owner != null) try self.execution.attestation.deinit();
    }
    pub fn cleanupDraft(self: *@This()) !void {
        if (self.execution.draft.owner != null) try self.execution.draft.deinit();
    }
    pub fn cleanupFiles(self: *@This()) !void {
        if (self.execution.files.owner != null) try self.execution.files.deinit();
    }
    pub fn cleanupProduct(self: *@This()) !void {
        if (self.execution.product.owner != null) try self.execution.product.deinit(self.execution.allocator);
    }
    pub fn cleanupSource(self: *@This()) !void {
        if (self.execution.source.owner != null) try self.execution.source.deinit();
    }
    pub fn cleanupIdentity(self: *@This()) !void {
        if (self.execution.identity.owner != null) try self.execution.identity.deinit();
    }
    pub fn cleanupCompatibility(self: *@This()) !void {
        if (self.execution.compatibility.owner != null) try self.execution.compatibility.deinit();
    }
};

fn validateStatic(i: Inputs, token: []const u8, scratch: []u8) !void {
    if (!i.context.protected_tag or i.context.repository.id == 0 or
        !std.mem.eql(u8, i.context.repository.owner, "ohah") or !std.mem.eql(u8, i.context.repository.name, "maru") or
        !scalar_identity.canonicalTag(i.context.tag) or !scalar_identity.lowerHex(i.context.source_commit, 40) or
        i.context.build.run_id == 0 or i.context.build.run_attempt == 0 or !release_evidence.canonicalReleaseTestUuid(i.test_uuid))
        return error.AuthorityMismatch;
    var workflow_storage: [context_mod.max_value_bytes]u8 = undefined;
    const expected_workflow = std.fmt.bufPrint(&workflow_storage, "ohah/maru/.github/workflows/release.yml@refs/tags/{s}", .{i.context.tag}) catch return error.AuthorityMismatch;
    if (!std.mem.eql(u8, i.context.build.workflow_ref, expected_workflow) or
        !validScalar(token, max_token_bytes) or scratch.len == 0 or scratch.len > max_scratch_bytes)
        return error.InvalidInput;
    try validatePaths(i.context.tag, i.paths, i.bundles);
}

fn validatePaths(tag: []const u8, paths: Paths, bundles: candidate_attestation.BundlePaths) !void {
    if (tag.len < 2) return error.InvalidPath;
    const values = [_][]const u8{ paths.dmg, paths.frozen_executable, paths.dmg_work, bundles.dmg_bundle, bundles.frozen_bundle };
    for (values) |path| if (!canonicalAbsolute(path)) return error.InvalidPath;
    for (values, 0..) |left, index| for (values[index + 1 ..]) |right| if (std.mem.eql(u8, left, right)) return error.InvalidPath;
    var dmg_storage: [context_mod.max_value_bytes]u8 = undefined;
    var frozen_storage: [context_mod.max_value_bytes]u8 = undefined;
    const version = tag[1..];
    const dmg_name = std.fmt.bufPrint(&dmg_storage, "Maru-{s}-universal.dmg", .{version}) catch return error.InvalidPath;
    const frozen_name = std.fmt.bufPrint(&frozen_storage, "maru-session-host-{s}", .{version}) catch return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(paths.dmg), dmg_name) or
        !std.mem.eql(u8, std.fs.path.basename(paths.frozen_executable), frozen_name)) return error.InvalidPath;
    const dmg_parent = std.fs.path.dirname(paths.dmg) orelse return error.InvalidPath;
    const frozen_parent = std.fs.path.dirname(paths.frozen_executable) orelse return error.InvalidPath;
    const work_parent = std.fs.path.dirname(paths.dmg_work) orelse return error.InvalidPath;
    if (std.mem.eql(u8, work_parent, dmg_parent) or std.mem.eql(u8, work_parent, frozen_parent)) return error.InvalidPath;
    var existing: std.posix.Stat = undefined;
    if (std.c.fstatat(std.posix.AT.FDCWD, paths.dmg_work.ptr, &existing, std.posix.AT.SYMLINK_NOFOLLOW) == 0 or
        std.posix.errno(-1) != .NOENT) return error.InvalidPath;
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

fn validateAttestation(i: Inputs, attestation: *const CandidateAttestation) !void {
    const value = try attestation.revalidate(filePaths(i.paths));
    if (!std.mem.eql(u8, value.tag, i.context.tag) or !std.mem.eql(u8, value.source_commit, i.context.source_commit) or
        !std.mem.eql(u8, value.build.workflow_ref, i.context.build.workflow_ref) or
        value.build.run_id != i.context.build.run_id or value.build.run_attempt != i.context.build.run_attempt)
        return error.AuthorityChanged;
}

fn validateDraft(i: Inputs, draft: *const DraftAuthority) !void {
    const value = draft.value() orelse return error.AuthorityChanged;
    if (!std.mem.eql(u8, value.tag, i.context.tag) or !std.mem.eql(u8, value.source_commit, i.context.source_commit))
        return error.AuthorityChanged;
}

fn validateSource(i: Inputs, source: *const SourceTreeAuthority) !void {
    const value = source.value() orelse return error.AuthorityChanged;
    if (!std.mem.eql(u8, value.commit, i.context.source_commit) or !scalar_identity.lowerHex(value.tree, 40)) return error.AuthorityChanged;
}

fn validateFiles(i: Inputs, execution: *const Execution) !void {
    if (execution.files.attestation != &execution.attestation) return error.AuthorityChanged;
    const draft = execution.draft.value() orelse return error.AuthorityChanged;
    const value = try execution.files.revalidate(filePaths(i.paths));
    if (value.release_id != draft.id or !std.mem.eql(u8, value.tag, i.context.tag) or
        !std.mem.eql(u8, value.source_commit, i.context.source_commit) or
        !std.mem.eql(u8, value.build.workflow_ref, i.context.build.workflow_ref) or
        value.build.run_id != i.context.build.run_id or value.build.run_attempt != i.context.build.run_attempt)
        return error.AuthorityChanged;
}

fn validateProduct(i: Inputs, execution: *const Execution) !void {
    const draft = execution.draft.value() orelse return error.AuthorityChanged;
    const value = try execution.product.revalidate(&execution.files, i.paths);
    if (value.release_id != draft.id or !std.mem.eql(u8, value.tag, i.context.tag) or
        !std.mem.eql(u8, value.source_commit, i.context.source_commit) or
        !std.mem.eql(u8, value.build.workflow_ref, i.context.build.workflow_ref) or
        value.build.run_id != i.context.build.run_id or value.build.run_attempt != i.context.build.run_attempt)
        return error.AuthorityChanged;
}

fn filePaths(paths: Paths) candidate_attestation.Paths {
    return .{ .dmg = paths.dmg, .frozen_executable = paths.frozen_executable };
}

fn validateAliases(i: Inputs, token: []const u8, scratch: []u8, execution: *Execution, deadline: ?*Deadline) !void {
    const result = std.mem.asBytes(execution);
    const pinned = std.mem.asBytes(i.cli.pinned);
    const values = [_][]const u8{
        i.context.repository.owner,   i.context.repository.name, i.context.tag,           i.context.source_commit,
        i.context.build.workflow_ref, i.test_uuid,               i.paths.dmg,             i.paths.frozen_executable,
        i.paths.dmg_work,             i.bundles.dmg_bundle,      i.bundles.frozen_bundle, i.cli.path,
        token,                        scratch,
    };
    if (overlaps(result, pinned)) return error.InvalidOwner;
    for (values, 0..) |value, index| {
        if (overlaps(result, value) or overlaps(pinned, value)) return error.InvalidOwner;
        for (values[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    }
    if (deadline) |value| {
        const bytes = std.mem.asBytes(value);
        if (overlaps(result, bytes) or overlaps(pinned, bytes)) return error.InvalidOwner;
        for (values) |item| if (overlaps(bytes, item)) return error.InvalidOwner;
    }
}

fn pristineAttestation(v: *const CandidateAttestation) bool {
    return v.owner == null and v.tag_len == 0 and v.workflow_ref_len == 0 and v.run_id == 0 and v.run_attempt == 0 and
        pristinePinned(&v.dmg) and pristinePinned(&v.frozen) and !v.dmg_attested and !v.frozen_attested and
        allZero(&v.tag) and allZero(&v.source_commit) and allZero(&v.workflow_ref);
}
fn pristineDraft(v: *const DraftAuthority) bool {
    return v.owner == null and v.state() == .empty and v.id == 0 and v.tag_len == 0 and
        allZero(&v.tag) and allZero(&v.source_commit);
}
fn pristineFiles(v: *const CandidateFiles) bool {
    return v.owner == null and v.attestation == null and v.release_id == 0;
}
fn pristineProduct(v: *const CandidateProduct) bool {
    return v.owner == null and v.release_id == 0 and v.tag_len == 0 and v.workflow_ref_len == 0 and
        v.run_id == 0 and v.run_attempt == 0 and v.observed == null and allZero(&v.tag) and
        allZero(&v.source_commit) and allZero(&v.workflow_ref) and allZero(&v.dmg_sha256) and allZero(&v.frozen_sha256);
}
fn pristineSource(v: *const SourceTreeAuthority) bool {
    return v.owner == null and std.mem.allEqual(u8, &v.commit, 0) and std.mem.allEqual(u8, &v.tree, 0);
}
fn pristineIdentity(v: *const CandidateEvidenceIdentity) bool {
    return v.owner == null and v.repository_id == 0 and v.release_id == 0 and v.tag_len == 0 and
        v.workflow_ref_len == 0 and v.run_id == 0 and v.run_attempt == 0 and allZero(&v.test_uuid) and
        allZero(&v.tag) and allZero(&v.source_commit) and allZero(&v.source_tree) and allZero(&v.workflow_ref) and
        allZero(&v.dmg_sha256) and allZero(&v.executable_sha256) and allZero(&v.designated_requirement_sha256);
}
fn pristineCompatibility(v: *const CandidateCompatibility) bool {
    return v.owner == null and v.release_id == 0 and v.tag_len == 0 and v.workflow_ref_len == 0 and
        v.run_id == 0 and v.run_attempt == 0 and allZero(&v.tag) and allZero(&v.source_commit) and
        allZero(&v.workflow_ref) and allZero(&v.executable_sha256) and v.compatibility.mrsh_major == 0 and
        v.compatibility.screen_codec == 0 and v.compatibility.handoff_reader_min == 0 and
        v.compatibility.handoff_reader_max == 0 and v.compatibility.app_host_abi == 0;
}

fn pristinePinned(v: *const @TypeOf(@as(CandidateAttestation, undefined).dmg)) bool {
    return v.owner == null and v.fd < 0 and v.parent_fd < 0 and v.path_len == 0 and
        allZero(&v.path_sha256) and allZero(&v.sha256) and !v.executable;
}

fn allZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn validScalar(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ae = std.math.add(usize, @intFromPtr(a.ptr), a.len) catch return true;
    const be = std.math.add(usize, @intFromPtr(b.ptr), b.len) catch return true;
    return @intFromPtr(a.ptr) < be and @intFromPtr(b.ptr) < ae;
}
