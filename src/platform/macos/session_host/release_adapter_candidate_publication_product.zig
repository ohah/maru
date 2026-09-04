//! Production owner for publishing one fully prepared candidate release.

const std = @import("std");
const phase = @import("release_adapter_candidate_publication_phase");
const deadline_mod = @import("release_adapter_deadline");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const compatibility_mod = @import("release_adapter_candidate_compatibility");
const candidate_manifest = @import("release_adapter_candidate_manifest");
const candidate_attestation = @import("release_adapter_candidate_attestation");
const candidate_authored = @import("release_adapter_candidate_authored_attestation");
const files_mod = @import("release_adapter_files");
const draft_creation = @import("release_adapter_github_draft_creation");
const draft_attachment = @import("release_adapter_github_draft_asset_attachment");
const draft_redownload = @import("release_adapter_github_draft_asset_redownload");
const draft_publication = @import("release_adapter_github_draft_publication");
const post_publish = @import("release_adapter_github_post_publish_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const evidence_mod = @import("release_evidence");
const manifest_mod = @import("release_manifest");

pub const Context = context_mod.Context;
pub const CandidateFiles = candidate_files.CandidateFiles;
pub const CandidateProduct = candidate_product.CandidateProduct;
pub const CandidateEvidenceIdentity = candidate_identity.CandidateEvidenceIdentity;
pub const SourceTreeAuthority = source_tree.SourceTreeAuthority;
pub const CandidateCompatibility = compatibility_mod.CandidateCompatibility;
pub const PinnedReleaseFile = files_mod.PinnedReleaseFile;
pub const DraftAuthority = draft_creation.DraftAuthority;
pub const CandidateAttestation = candidate_attestation.CandidateAttestation;
pub const PinnedCli = cli_authority.PinnedExecutable;
pub const Deadline = deadline_mod.Deadline;

pub const Paths = struct { dmg: [:0]const u8, frozen_executable: [:0]const u8, evidence: [:0]const u8, manifest: [:0]const u8 };
pub const Cli = struct { path: [:0]const u8, pinned: *const PinnedCli };
pub const Inputs = struct {
    context: Context,
    identity: *const CandidateEvidenceIdentity,
    files: *const CandidateFiles,
    product: *const CandidateProduct,
    product_paths: candidate_product.Paths,
    source: *const SourceTreeAuthority,
    compatibility: *const CandidateCompatibility,
    evidence: *const PinnedReleaseFile,
    draft: *const DraftAuthority,
    candidate_attestation: *const CandidateAttestation,
    cli: Cli,
    paths: Paths,
    predecessor: ?candidate_manifest.PredecessorGraph = null,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: phase.Publication = .{},
    deadline: deadline_mod.Deadline = .{},
    manifest: PinnedReleaseFile = .{},
    authored: candidate_authored.AuthoredAttestation = .{},
    attached: draft_attachment.DraftAssets = .{},
    redownloaded: draft_redownload.RedownloadValidation = .{},
    published: draft_publication.PublishedRelease = .{},
    verified: post_publish.VerifiedRelease = .{},
    inputs: ?Inputs = null,
    token: []const u8 = "",
    response: []u8 = &.{},
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,
    audit_storage: ?[]u8 = null,
    audit_len: usize = 0,
    active_deadline: ?*Deadline = null,

    pub fn isPristineForComposition(self: *const @This()) bool {
        return self.pristine();
    }
    pub fn ownsSuccessfulOutputs(self: *const @This()) bool {
        return self.owner == self and self.transaction.ownsCompletePublication() and self.deadline.isPristineForComposition() and
            self.manifest.owner == &self.manifest and self.authored.owner == &self.authored and
            self.attached.owner == &self.attached and self.redownloaded.owner == &self.redownloaded and
            self.published.owner == &self.published and self.verified.owner == &self.verified and !self.hasBorrowed();
    }
    pub fn revalidateSuccessfulOutputs(self: *const @This(), allocator: std.mem.Allocator, inputs_value: Inputs) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        const storage = try allocator.alloc(u8, phase.max_audit_bytes);
        defer allocator.free(storage);
        _ = try buildAudit(allocator, inputs_value, storage, &self.manifest);
    }
    pub fn needsAudit(self: *const @This()) bool {
        return self.owner == self and self.transaction.needsAudit() and self.deadline.isPristineForComposition() and !self.hasBorrowed();
    }
    pub fn cleanup(self: *@This()) !void {
        if (!self.ownsSuccessfulOutputs()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.cleanupWith(&steps, &self.transaction);
        self.* = .{};
    }
    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or !self.transaction.needsCleanup() or !self.deadline.isPristineForComposition() or self.hasBorrowed()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        try phase.retryCleanupWith(&steps, &self.transaction);
        self.* = .{};
    }
    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and self.deadline.isPristineForComposition() and pristineManifest(&self.manifest) and
            pristineAuthored(&self.authored) and pristineAttachment(&self.attached) and pristineRedownload(&self.redownloaded) and
            pristinePublished(&self.published) and pristineVerified(&self.verified) and !self.hasBorrowed() and
            self.audit_storage == null and self.audit_len == 0;
    }
    fn hasBorrowed(self: *const @This()) bool {
        return self.inputs != null or self.token.len != 0 or self.response.len != 0 or self.active_deadline != null;
    }
    fn clearBorrowed(self: *@This()) void {
        self.inputs = null;
        self.token = "";
        self.response = &.{};
        self.active_deadline = null;
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, token: []const u8, response: []u8, budget_ns: i128, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    try validateAliases(inputs, token, response, execution, null);
    try deadline_mod.start(budget_ns, &execution.deadline);
    return runWithDeadline(io, allocator, inputs, token, response, &execution.deadline, true, execution);
}

pub fn runBorrowingDeadline(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, token: []const u8, response: []u8, deadline: *Deadline, execution: *Execution) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    try validateAliases(inputs, token, response, execution, deadline);
    _ = try deadline.remaining();
    return runWithDeadline(io, allocator, inputs, token, response, deadline, false, execution);
}

fn runWithDeadline(io: std.Io, allocator: std.mem.Allocator, inputs: Inputs, token: []const u8, response: []u8, deadline: *Deadline, owns_deadline: bool, execution: *Execution) !void {
    execution.owner = execution;
    execution.inputs = inputs;
    execution.token = token;
    execution.response = response;
    execution.io = io;
    execution.allocator = allocator;
    execution.active_deadline = deadline;
    errdefer {
        if (execution.owner == execution and execution.transaction.isPristineForComposition()) execution.* = .{};
    }
    var steps = ConcreteSteps{ .execution = execution };
    const outcome = phase.executeWith(&steps, deadline, &execution.transaction);
    releaseAudit(execution);
    execution.clearBorrowed();
    if (owns_deadline and execution.deadline.owner != null) execution.deadline.deinit() catch return error.CleanupFailed;
    outcome catch |err| {
        if (execution.transaction.isPristineForComposition()) execution.* = .{};
        return err;
    };
}

fn releaseAudit(execution: *Execution) void {
    if (execution.audit_storage) |storage| execution.allocator.free(storage);
    execution.audit_storage = null;
    execution.audit_len = 0;
}

const ConcreteSteps = struct {
    execution: *Execution,
    fn input(self: *@This()) !Inputs {
        return self.execution.inputs orelse error.InvalidOwner;
    }
    pub fn validatePreflight(self: *@This(), publication: *phase.Publication, deadline: *deadline_mod.Deadline) !void {
        if (publication != &self.execution.transaction or deadline != self.execution.active_deadline or self.execution.owner != self.execution) return error.InvalidOwner;
        _ = try self.input();
    }
    pub fn captureAuditBytes(self: *@This(), deadline: *deadline_mod.Deadline) ![]const u8 {
        _ = try deadline.remaining();
        const storage = try self.execution.allocator.alloc(u8, phase.max_audit_bytes);
        errdefer self.execution.allocator.free(storage);
        const used = try buildAudit(self.execution.allocator, try self.input(), storage, null);
        self.execution.audit_storage = storage;
        self.execution.audit_len = used.len;
        return used;
    }
    pub fn validateAuthority(self: *@This(), deadline: *deadline_mod.Deadline, seal: [32]u8) !void {
        _ = try deadline.remaining();
        const storage = try self.execution.allocator.alloc(u8, phase.max_audit_bytes);
        defer self.execution.allocator.free(storage);
        const held_manifest: ?*const PinnedReleaseFile = if (self.execution.manifest.owner != null) &self.execution.manifest else null;
        const used = try buildAudit(self.execution.allocator, try self.input(), storage, held_manifest);
        if (!std.mem.eql(u8, &phase.deriveAuditSeal(used), &seal)) return error.AuthorityChanged;
        // executeWith has copied the domain-separated seal before its first fence. The initial
        // snapshot backing is no longer authority and must not survive the fence.
        releaseAudit(self.execution);
        _ = try deadline.remaining();
    }
    pub fn authorManifest(self: *@This(), _: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try candidate_manifest.author(self.execution.allocator, i.context, i.identity, i.files, i.product, i.product_paths, i.source, i.compatibility, i.evidence, manifestPaths(i), i.predecessor, &self.execution.manifest);
    }
    pub fn attestAuthored(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        var authority = candidate_manifest.initAuthority(i.context, i.identity, i.files, i.product, i.product_paths, i.source, i.compatibility, i.predecessor);
        try candidate_authored.composeUntil(self.execution.io, self.execution.allocator, i.context, &authority, i.evidence, &self.execution.manifest, manifestPaths(i), .{ .path = i.cli.path, .pinned = i.cli.pinned }, self.execution.token, self.execution.response, deadline, &self.execution.authored);
    }
    pub fn attachAssets(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try draft_attachment.attachUntil(self.execution.io, self.execution.allocator, i.context, i.draft, i.candidate_attestation, &self.execution.authored, i.evidence, &self.execution.manifest, attachmentPaths(i), .{ .path = i.cli.path, .pinned = i.cli.pinned }, self.execution.token, self.execution.response, deadline, &self.execution.attached);
    }
    pub fn attachmentRequiresAudit(self: *@This()) bool {
        return self.execution.attached.state() != .empty;
    }
    pub fn validateRedownload(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try draft_redownload.validateUntil(self.execution.io, authorityInput(self.execution.allocator, i, self.execution), &self.execution.attached, self.execution.token, deadline, &self.execution.redownloaded);
    }
    pub fn publishDraft(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try draft_publication.publishUntil(self.execution.io, authorityInput(self.execution.allocator, i, self.execution), &self.execution.attached, &self.execution.redownloaded, self.execution.token, self.execution.response, deadline, &self.execution.published);
    }
    pub fn verifyPublished(self: *@This(), deadline: *deadline_mod.Deadline) !void {
        const i = try self.input();
        try post_publish.verifyUntil(self.execution.io, authorityInput(self.execution.allocator, i, self.execution), &self.execution.attached, &self.execution.redownloaded, &self.execution.published, self.execution.token, self.execution.response, deadline, &self.execution.verified);
    }
    pub fn cleanupManifest(self: *@This()) !void {
        if (self.execution.manifest.owner != null) try self.execution.manifest.deinit();
    }
    pub fn cleanupAttestation(self: *@This()) !void {
        if (self.execution.authored.owner != null) try self.execution.authored.deinit();
    }
    pub fn cleanupAttachment(self: *@This()) !void {
        if (self.execution.attached.owner != null) try self.execution.attached.deinit();
    }
    pub fn cleanupRedownload(self: *@This()) !void {
        if (self.execution.redownloaded.owner != null) try self.execution.redownloaded.deinit();
    }
    pub fn cleanupPublication(self: *@This()) !void {
        if (self.execution.published.owner != null) try self.execution.published.deinit();
    }
    pub fn cleanupVerification(self: *@This()) !void {
        if (self.execution.verified.owner != null) try self.execution.verified.deinit();
    }
};

fn manifestPaths(i: Inputs) candidate_manifest.Paths {
    return .{ .dmg = i.paths.dmg, .frozen_executable = i.paths.frozen_executable, .evidence = i.paths.evidence, .output = i.paths.manifest };
}
fn attachmentPaths(i: Inputs) draft_attachment.Paths {
    return .{ .dmg = i.paths.dmg, .frozen_executable = i.paths.frozen_executable, .evidence = i.paths.evidence, .manifest = i.paths.manifest };
}
fn authorityInput(allocator: std.mem.Allocator, i: Inputs, e: *Execution) draft_attachment.AuthorityInput {
    return .{ .allocator = allocator, .context = i.context, .draft = i.draft, .candidate = i.candidate_attestation, .authored = &e.authored, .evidence = i.evidence, .manifest = &e.manifest, .paths = attachmentPaths(i), .cli = .{ .path = i.cli.path, .pinned = i.cli.pinned } };
}

fn buildAudit(allocator: std.mem.Allocator, i: Inputs, storage: []u8, held_manifest: ?*const PinnedReleaseFile) ![]const u8 {
    try cli_authority.revalidate(allocator, i.cli.path, i.cli.pinned);
    const draft = i.draft.value() orelse return error.InvalidDraft;
    const candidate = try i.candidate_attestation.revalidate(.{ .dmg = i.paths.dmg, .frozen_executable = i.paths.frozen_executable });
    if (!std.mem.eql(u8, candidate.tag, i.context.tag) or !std.mem.eql(u8, candidate.source_commit, i.context.source_commit) or
        !std.mem.eql(u8, candidate.build.workflow_ref, i.context.build.workflow_ref) or candidate.build.run_id != i.context.build.run_id or
        candidate.build.run_attempt != i.context.build.run_attempt) return error.AuthorityChanged;
    var evidence_input = try i.evidence.readHeldAlloc(allocator, i.paths.evidence, evidence_mod.max_evidence_bytes);
    defer evidence_input.deinit(allocator);
    var parsed = try evidence_mod.parseCanonical(allocator, evidence_input.bytes);
    defer parsed.deinit();
    var authority = candidate_manifest.initAuthority(i.context, i.identity, i.files, i.product, i.product_paths, i.source, i.compatibility, i.predecessor);
    const bundle = try authority.revalidate(parsed.profile(), i.evidence.value() orelse return error.InvalidOwner, manifestPaths(i));
    const canonical = try manifest_mod.writeCanonical(allocator, bundle.value);
    defer allocator.free(canonical);
    if (held_manifest) |manifest| {
        var held = try manifest.readHeldAlloc(allocator, i.paths.manifest, manifest_mod.max_manifest_bytes);
        defer held.deinit(allocator);
        if (!std.mem.eql(u8, canonical, held.bytes)) return error.AuthorityChanged;
    }
    if (draft.id != bundle.value.release.id or !std.mem.eql(u8, draft.tag, bundle.value.release.tag) or !std.mem.eql(u8, draft.source_commit, bundle.value.source.commit)) return error.AuthorityChanged;
    var writer = std.Io.Writer.fixed(storage);
    writer.print("candidate-publication-v1\nmanifest:{d}:{s}\n", .{ canonical.len, canonical }) catch return error.AuditTooLarge;
    writer.print("context:{d}:{d}:{s}:{d}:{s}:{d}:{s}:{d}:{d}:{any}\ndraft:{d}\n", .{ i.context.repository.id, i.context.repository.owner.len, i.context.repository.owner, i.context.repository.name.len, i.context.repository.name, i.context.tag.len, i.context.tag, i.context.build.run_id, i.context.build.run_attempt, i.context.protected_tag, draft.id }) catch return error.AuditTooLarge;
    writer.print("cli:{d}:{d}:{d}:{d}:{s}:{s}\n", .{ i.cli.pinned.identity.device, i.cli.pinned.identity.inode, i.cli.pinned.mode, i.cli.pinned.size, &i.cli.pinned.path_sha256, &i.cli.pinned.sha256 }) catch return error.AuditTooLarge;
    writer.print("dmg:{d}:{d}:{d}:{d}:{s}\nfrozen:{d}:{d}:{d}:{d}:{s}\nevidence:{d}:{d}:{d}:{d}:{s}\n", .{ candidate.dmg.identity.device, candidate.dmg.identity.inode, candidate.dmg.mode, candidate.dmg.size, &candidate.dmg.sha256, candidate.frozen.identity.device, candidate.frozen.identity.inode, candidate.frozen.mode, candidate.frozen.size, &candidate.frozen.sha256, evidence_input.identity.device, evidence_input.identity.inode, evidence_input.mode, evidence_input.size, &evidence_input.sha256 }) catch return error.AuditTooLarge;
    writer.print("paths:{d}:{s}:{d}:{s}:{d}:{s}:{d}:{s}\n", .{ i.paths.dmg.len, i.paths.dmg, i.paths.frozen_executable.len, i.paths.frozen_executable, i.paths.evidence.len, i.paths.evidence, i.paths.manifest.len, i.paths.manifest }) catch return error.AuditTooLarge;
    return writer.buffered();
}

fn validateAliases(i: Inputs, token: []const u8, response: []u8, execution: *Execution, deadline: ?*Deadline) !void {
    const result = std.mem.asBytes(execution);
    const owners = [_][]const u8{ std.mem.asBytes(i.identity), std.mem.asBytes(i.files), std.mem.asBytes(i.product), std.mem.asBytes(i.source), std.mem.asBytes(i.compatibility), std.mem.asBytes(i.evidence), std.mem.asBytes(i.draft), std.mem.asBytes(i.candidate_attestation), std.mem.asBytes(i.cli.pinned) };
    for (owners, 0..) |value, index| for (owners[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    const product_paths = [_][]const u8{ i.product_paths.dmg, i.product_paths.frozen_executable, i.product_paths.dmg_work };
    const release_paths = [_][]const u8{ i.paths.dmg, i.paths.frozen_executable, i.paths.evidence, i.paths.manifest };
    for (product_paths, 0..) |value, index| for (product_paths[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    for (release_paths, 0..) |value, index| for (release_paths[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
    const context = [_][]const u8{ i.context.repository.owner, i.context.repository.name, i.context.tag, i.context.source_commit, i.context.build.workflow_ref };
    const values = owners ++ product_paths ++ release_paths ++ context ++ [_][]const u8{i.cli.path};
    for (values) |value| {
        if (overlaps(result, value) or overlaps(response, value) or overlaps(token, value)) return error.InvalidOwner;
    }
    if (i.predecessor) |predecessor| {
        const predecessor_owners = [_][]const u8{ std.mem.asBytes(predecessor.identity), std.mem.asBytes(predecessor.authenticated), std.mem.asBytes(predecessor.held_manifest), std.mem.asBytes(predecessor.assets) };
        for (predecessor_owners, 0..) |value, index| {
            if (overlaps(result, value) or overlaps(response, value) or overlaps(token, value)) return error.InvalidOwner;
            for (owners) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
            for (predecessor_owners[0..index]) |prior| if (overlaps(value, prior)) return error.InvalidOwner;
        }
    }
    if (overlaps(result, token) or overlaps(result, response)) return error.InvalidOwner;
    if (overlaps(token, response)) return error.InvalidOwner;
    if (deadline) |value| {
        const bytes = std.mem.asBytes(value);
        if (overlaps(result, bytes) or overlaps(token, bytes) or overlaps(response, bytes)) return error.InvalidOwner;
        for (values) |item| if (overlaps(bytes, item)) return error.InvalidOwner;
        if (i.predecessor) |predecessor| {
            for ([_][]const u8{ std.mem.asBytes(predecessor.identity), std.mem.asBytes(predecessor.authenticated), std.mem.asBytes(predecessor.held_manifest), std.mem.asBytes(predecessor.assets) }) |owner_bytes|
                if (overlaps(bytes, owner_bytes)) return error.InvalidOwner;
        }
    }
    if (response.len == 0) return error.InvalidBuffer;
}

fn pristineManifest(value: *const PinnedReleaseFile) bool {
    return value.owner == null and value.fd < 0 and value.parent_fd < 0 and value.path_len == 0 and
        std.mem.allEqual(u8, &value.path_sha256, 0) and std.mem.allEqual(u8, &value.sha256, 0) and !value.executable;
}
fn pristineAuthored(value: *const candidate_authored.AuthoredAttestation) bool {
    return value.owner == null and value.repository_id == 0 and value.repository_owner_len == 0 and value.repository_name_len == 0 and
        value.release_id == 0 and value.tag_len == 0 and value.workflow_ref_len == 0 and value.run_id == 0 and value.run_attempt == 0 and
        !value.protected_tag and !value.evidence_attested and !value.manifest_attested;
}
fn pristineAttachment(value: *const draft_attachment.DraftAssets) bool {
    return value.owner == null and value.state() == .empty and value.release_id == 0 and value.known_count == 0 and
        std.mem.allEqual(u64, &value.ids, 0) and std.mem.allEqual(u64, &value.sizes, 0) and std.mem.allEqual(usize, &value.name_lens, 0);
}
fn pristineRedownload(value: *const draft_redownload.RedownloadValidation) bool {
    return value.owner == null and value.state() == .empty and value.release_id == 0 and std.mem.allEqual(u64, &value.asset_ids, 0);
}
fn pristinePublished(value: *const draft_publication.PublishedRelease) bool {
    return value.owner == null and value.state() == .empty and value.release_id == 0 and value.tag_len == 0 and
        std.mem.allEqual(u64, &value.asset_ids, 0);
}
fn pristineVerified(value: *const post_publish.VerifiedRelease) bool {
    return value.owner == null and value.release_id == 0 and value.tag_len == 0 and std.mem.allEqual(u64, &value.artifact_ids, 0);
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ae = std.math.add(usize, @intFromPtr(a.ptr), a.len) catch return true;
    const be = std.math.add(usize, @intFromPtr(b.ptr), b.len) catch return true;
    return @intFromPtr(a.ptr) < be and @intFromPtr(b.ptr) < ae;
}
