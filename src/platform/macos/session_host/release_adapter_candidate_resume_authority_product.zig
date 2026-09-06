//! Rebuilds the authority needed by a post-stage-4 publication process.

const std = @import("std");
const builtin = @import("builtin");
const phase = @import("release_adapter_candidate_resume_authority_phase");
const manifest_mod = @import("release_manifest");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const preparation_mod = @import("release_adapter_candidate_preparation_reopen");
const aggregate_mod = @import("release_adapter_candidate_aggregate_reopen");
const current_mod = @import("release_adapter_github_current_release_authority");
const adoption = @import("release_adapter_github_draft_adoption");
const draft_mod = @import("release_adapter_github_draft_creation");
const cli_mod = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");

pub const Paths = struct {
    preparation: [:0]const u8,
    aggregate: [:0]const u8,
    dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
};

pub const Inputs = struct {
    context: context_mod.Context,
    paths: Paths,
    cli_path: [:0]const u8,
    cli: *const cli_mod.PinnedExecutable,
};

pub const View = struct {
    preparation: preparation_mod.View,
    aggregate: aggregate_mod.View,
    draft: draft_mod.View,
};

pub const PublicationContext = context_mod.Context;
pub const PublicationObservation = files.ExecutableObservation;
pub const publication_asset_count: usize = 4;
pub const PublicationAsset = struct {
    path: []const u8,
    observation: PublicationObservation,
    fd: std.c.fd_t,
};
pub const PublicationView = struct {
    context: PublicationContext,
    release_id: u64,
    tag: []const u8,
    source_commit: []const u8,
    cli_sha256: [64]u8,
    assets: [publication_asset_count]PublicationAsset,
};

pub const Execution = struct {
    owner: ?*Execution = null,
    transaction: phase.Transaction = .{},
    deadline: deadline_mod.Deadline = .{},
    preparation: preparation_mod.ReopenedPreparation = .{},
    aggregate: aggregate_mod.ReopenedAggregate = .{},
    current: current_mod.CurrentReleaseAuthority = .{},
    draft: draft_mod.DraftAuthority = .{},
    inputs: ?Inputs = null,
    token: []const u8 = "",
    response: []u8 = &.{},
    io: std.Io = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !self.transaction.isReady() or !self.deadline.isPristineForComposition() or self.hasBorrowed()) return null;
        return .{
            .preparation = self.preparation.value() orelse return null,
            .aggregate = self.aggregate.value() orelse return null,
            .draft = self.draft.value() orelse return null,
        };
    }

    /// Re-fences the retained local graph and projects the exact held descriptors needed by the
    /// four existing publication leaves. No process-local pre-resume authority is reconstructed.
    pub fn publicationView(
        self: *const @This(),
        allocator: std.mem.Allocator,
        context: PublicationContext,
        cli_path: [:0]const u8,
        cli: *const cli_mod.PinnedExecutable,
    ) !PublicationView {
        if (!validReadyScalars(self)) return error.InvalidOwner;
        const ready = self.value() orelse return error.InvalidOwner;
        const aggregate_cli_path = try aggregateCliPath(self);
        if (!std.mem.eql(u8, cli_path, aggregate_cli_path)) return error.AuthorityChanged;

        var fenced = try fenceLocalGraph(self, allocator, context, cli_path, cli);
        defer fenced.manifest.deinit();
        try requireReadyAuthority(context, fenced.manifest.value(), self.current.value(), ready.draft);

        return .{
            .context = context,
            .release_id = ready.draft.id,
            .tag = ready.draft.tag,
            .source_commit = ready.draft.source_commit,
            .cli_sha256 = cli.sha256,
            .assets = .{
                .{ .path = aggregateArtifactPath(self, 0) catch return error.AuthorityChanged, .observation = fenced.aggregate.artifacts[0], .fd = try self.aggregate.artifacts[0].heldDescriptor() },
                .{ .path = aggregateArtifactPath(self, 1) catch return error.AuthorityChanged, .observation = fenced.aggregate.artifacts[1], .fd = try self.aggregate.artifacts[1].heldDescriptor() },
                .{ .path = aggregateEntryPath(self, 0) catch return error.AuthorityChanged, .observation = fenced.aggregate.entries[0], .fd = try self.aggregate.entries[0].heldDescriptor() },
                .{ .path = fenced.preparation.entries[1].path, .observation = fenced.preparation.entries[1].observation, .fd = try self.preparation.entries[1].heldDescriptor() },
            },
        };
    }

    pub fn cleanup(self: *@This()) !void {
        if (self.value() == null) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        const disposition = try phase.cleanupReadyWith(&steps, &self.transaction);
        self.* = .{};
        if (disposition == .descriptor_close_failed) return error.DescriptorCloseFailed;
    }

    pub fn retryAuditCleanup(self: *@This()) !void {
        if (self.owner != self or self.hasBorrowed() or !self.transaction.needsAudit()) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        const disposition = if (self.transaction.state == .audit_required)
            try phase.settleFailureWith(&steps, &self.transaction)
        else if (self.transaction.state == .audit_cleanup_required)
            try phase.retryCleanupWith(&steps, &self.transaction)
        else
            return error.InvalidOwner;
        if (disposition == .descriptor_close_failed) return error.DescriptorCloseFailed;
    }

    pub fn retryCleanup(self: *@This()) !void {
        if (self.owner != self or self.hasBorrowed() or self.transaction.state != .ready_cleanup_required) return error.InvalidOwner;
        var steps = ConcreteSteps{ .execution = self };
        const disposition = try phase.retryReadyCleanupWith(&steps, &self.transaction);
        self.* = .{};
        if (disposition == .descriptor_close_failed) return error.DescriptorCloseFailed;
    }

    fn pristine(self: *const @This()) bool {
        return self.owner == null and self.transaction.isPristineForComposition() and self.deadline.isPristineForComposition() and
            std.meta.eql(self.preparation, preparation_mod.ReopenedPreparation{}) and
            std.meta.eql(self.aggregate, aggregate_mod.ReopenedAggregate{}) and
            std.meta.eql(self.current, current_mod.CurrentReleaseAuthority{}) and
            std.meta.eql(self.draft, draft_mod.DraftAuthority{}) and
            !self.hasBorrowed();
    }

    fn hasBorrowed(self: *const @This()) bool {
        return self.inputs != null or self.token.len != 0 or self.response.len != 0;
    }
};

fn validReadyScalars(execution: *const Execution) bool {
    return execution.draft.id != 0 and execution.draft.tag_len != 0 and execution.draft.tag_len <= execution.draft.tag.len and
        execution.current.release_id != 0 and execution.current.tag_len != 0 and execution.current.tag_len <= execution.current.tag.len;
}

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: Inputs,
    token: []const u8,
    response: []u8,
    budget_ns: i128,
    execution: *Execution,
) !void {
    if (!execution.pristine()) return error.InvalidOwner;
    try validateInputs(inputs, token, response, execution);
    try deadline_mod.start(budget_ns, &execution.deadline);
    execution.owner = execution;
    execution.inputs = inputs;
    execution.token = token;
    execution.response = response;
    execution.io = io;
    execution.allocator = allocator;
    var steps = ConcreteSteps{ .execution = execution };
    const outcome = phase.executeWith(&steps, &execution.transaction);
    execution.inputs = null;
    execution.token = "";
    execution.response = &.{};
    execution.deadline.deinit() catch return error.CleanupFailed;
    return outcome;
}

const ConcreteSteps = struct {
    execution: *Execution,

    fn input(self: *@This()) !Inputs {
        return self.execution.inputs orelse error.InvalidOwner;
    }

    pub fn validatePreflight(self: *@This()) !void {
        if (self.execution.owner != self.execution or self.execution.transaction.owner != &self.execution.transaction or
            self.execution.deadline.owner != &self.execution.deadline) return error.InvalidOwner;
        const value = try self.input();
        try validateInputs(value, self.execution.token, self.execution.response, self.execution);
        _ = try self.execution.deadline.remaining();
    }

    pub fn openPreparation(self: *@This()) !void {
        const value = try self.input();
        try preparation_mod.open(self.execution.allocator, value.context, value.paths.preparation, &self.execution.preparation);
    }

    pub fn fencePreparation(self: *@This(), _: bool) !void {
        _ = try self.execution.preparation.fence(self.execution.allocator);
        _ = try self.execution.deadline.remaining();
    }

    pub fn openAggregate(self: *@This()) !void {
        const value = try self.input();
        _ = self.execution.preparation.value() orelse return error.InvalidOwner;
        const manifest_path = try manifestPath(self.execution);
        try aggregate_mod.openAndVerifyUntil(self.execution.io, self.execution.allocator, value.context, .{
            .directory = value.paths.aggregate,
            .dmg = value.paths.dmg,
            .frozen_executable = value.paths.frozen_executable,
            .manifest = manifest_path,
        }, .{ .path = value.cli_path, .pinned = value.cli }, self.execution.response, &self.execution.deadline, &self.execution.aggregate);
    }

    pub fn fenceAggregate(self: *@This(), _: bool) !void {
        const value = try self.input();
        var fenced = try fenceLocalGraph(self.execution, self.execution.allocator, value.context, value.cli_path, value.cli);
        defer fenced.manifest.deinit();
        _ = try self.execution.deadline.remaining();
    }

    pub fn authenticateCurrent(self: *@This()) !void {
        const value = try self.input();
        var parsed = try self.readManifest();
        defer parsed.deinit();
        try current_mod.authenticateUntil(self.execution.io, self.execution.allocator, value.context, parsed.value().*, .{
            .path = value.cli_path,
            .pinned = value.cli,
        }, self.execution.token, self.execution.response, &self.execution.deadline, &self.execution.current);
    }

    pub fn adoptDraft(self: *@This()) !void {
        const value = try self.input();
        var parsed = try self.readManifest();
        defer parsed.deinit();
        try adoption.adopt(value.context, parsed.value().*, &self.execution.current, &self.execution.draft);
    }

    pub fn cleanupDraft(self: *@This()) !phase.CleanupDisposition {
        if (self.execution.draft.owner != null) try self.execution.draft.deinit();
        return .complete;
    }

    pub fn cleanupCurrent(self: *@This()) !phase.CleanupDisposition {
        if (self.execution.current.owner != null) try self.execution.current.deinit();
        return .complete;
    }

    pub fn cleanupAggregateAudit(self: *@This()) !phase.CleanupDisposition {
        if (self.execution.aggregate.owner != null)
            self.execution.aggregate.deinit() catch |err| switch (err) {
                else => return classifyCloseErrorImpl(err),
            };
        return .complete;
    }

    pub fn cleanupPreparationAudit(self: *@This()) !phase.CleanupDisposition {
        if (self.execution.preparation.owner != null)
            self.execution.preparation.deinit() catch |err| switch (err) {
                else => return classifyCloseErrorImpl(err),
            };
        return .complete;
    }

    pub fn cleanupAggregateReady(self: *@This()) !phase.CleanupDisposition {
        if (self.execution.aggregate.owner != null)
            self.execution.aggregate.close() catch |err| switch (err) {
                else => return classifyCloseErrorImpl(err),
            };
        return .complete;
    }

    pub fn cleanupPreparationReady(self: *@This()) !phase.CleanupDisposition {
        if (self.execution.preparation.owner != null)
            self.execution.preparation.close(self.execution.allocator) catch |err| switch (err) {
                else => return classifyCloseErrorImpl(err),
            };
        return .complete;
    }

    fn readManifest(self: *@This()) !manifest_mod.Parsed {
        _ = self.execution.preparation.value() orelse return error.InvalidOwner;
        const path = try manifestPath(self.execution);
        var held = try self.execution.preparation.entries[1].readHeldAlloc(self.execution.allocator, path, manifest_mod.max_manifest_bytes);
        defer held.deinit(self.execution.allocator);
        return manifest_mod.parseCanonical(self.execution.allocator, held.bytes);
    }
};

const FencedLocalGraph = struct {
    preparation: preparation_mod.View,
    aggregate: aggregate_mod.View,
    manifest: manifest_mod.Parsed,
};

fn fenceLocalGraph(
    execution: *const Execution,
    allocator: std.mem.Allocator,
    context: PublicationContext,
    cli_path: [:0]const u8,
    cli: *const cli_mod.PinnedExecutable,
) !FencedLocalGraph {
    const preparation = try execution.preparation.fence(allocator);
    const aggregate = try execution.aggregate.fence();
    try cli_mod.revalidate(allocator, cli_path, cli);
    try requireCrossIdentityGraph(preparation, aggregate, cli);
    var parsed = try readManifestFor(execution, allocator);
    errdefer parsed.deinit();
    try context_mod.bindManifest(context, parsed.value().*);
    try requireSemanticGraphImpl(parsed.value(), .{
        .preparation_evidence = preparation.entries[0].observation,
        .preparation_manifest = preparation.entries[1].observation,
        .aggregate_evidence = aggregate.entries[0],
        .aggregate_dmg = aggregate.artifacts[0],
        .aggregate_frozen = aggregate.artifacts[1],
        .aggregate_manifest = aggregate.artifacts[2],
        .dmg_name = std.fs.path.basename(try aggregateArtifactPath(execution, 0)),
        .frozen_name = std.fs.path.basename(try aggregateArtifactPath(execution, 1)),
        .evidence_name = aggregate.evidence_name,
    });
    return .{ .preparation = preparation, .aggregate = aggregate, .manifest = parsed };
}

fn requireReadyAuthority(
    context: PublicationContext,
    manifest: *const manifest_mod.Manifest,
    current: ?current_mod.View,
    draft: draft_mod.View,
) !void {
    const authenticated = current orelse return error.InvalidOwner;
    if (!context.protected_tag or manifest.role != .a or manifest.predecessor != null or
        authenticated.repository_id != context.repository.id or
        authenticated.run_id != context.build.run_id or
        authenticated.run_attempt != context.build.run_attempt or
        !std.mem.eql(u8, authenticated.source_commit, context.source_commit) or
        authenticated.job_id == 0 or authenticated.deployment_id == 0 or authenticated.environment_id == 0 or
        !authenticated.protected_environment or
        authenticated.release_id != manifest.release.id or
        !std.mem.eql(u8, authenticated.tag, manifest.release.tag) or
        draft.id != manifest.release.id or
        !std.mem.eql(u8, draft.tag, context.tag) or
        !std.mem.eql(u8, draft.source_commit, context.source_commit)) return error.AuthorityChanged;
}

fn readManifestFor(execution: *const Execution, allocator: std.mem.Allocator) !manifest_mod.Parsed {
    _ = execution.preparation.value() orelse return error.InvalidOwner;
    const path = try manifestPath(execution);
    var held = try execution.preparation.entries[1].readHeldAlloc(allocator, path, manifest_mod.max_manifest_bytes);
    defer held.deinit(allocator);
    return manifest_mod.parseCanonical(allocator, held.bytes);
}

fn aggregateCliPath(execution: *const Execution) ![:0]const u8 {
    const len = execution.aggregate.cli_path_len;
    if (len == 0 or len >= execution.aggregate.cli_path.len) return error.InvalidPath;
    return execution.aggregate.cli_path[0..len :0];
}

fn aggregateEntryPath(execution: *const Execution, index: usize) ![:0]const u8 {
    if (index >= execution.aggregate.paths.len) return error.InvalidPath;
    const len = execution.aggregate.path_lens[index];
    if (len == 0 or len >= execution.aggregate.paths[index].len) return error.InvalidPath;
    return execution.aggregate.paths[index][0..len :0];
}

fn aggregateArtifactPath(execution: *const Execution, index: usize) ![:0]const u8 {
    if (index >= execution.aggregate.artifact_paths.len) return error.InvalidPath;
    const len = execution.aggregate.artifact_path_lens[index];
    if (len == 0 or len >= execution.aggregate.artifact_paths[index].len) return error.InvalidPath;
    return execution.aggregate.artifact_paths[index][0..len :0];
}

fn requireCrossIdentityGraph(preparation: preparation_mod.View, aggregate: aggregate_mod.View, cli: *const cli_mod.PinnedExecutable) !void {
    const identities: [11]files.Identity = .{
        preparation.entries[0].observation.identity,
        preparation.entries[1].observation.identity,
        aggregate.entries[0].identity,
        aggregate.entries[1].identity,
        aggregate.entries[2].identity,
        aggregate.entries[3].identity,
        aggregate.entries[4].identity,
        aggregate.artifacts[0].identity,
        aggregate.artifacts[1].identity,
        aggregate.artifacts[2].identity,
        cli.identity,
    };
    try requireIdentityGraphImpl(identities);
}

fn requireIdentityGraphImpl(identities: [11]files.Identity) !void {
    // The aggregate deliberately reopens the manifest held by the preparation owner. Those two
    // descriptor owners must name the same vnode; treating that required overlap as a hostile
    // alias would make every concrete resume fail immediately before current-draft authentication.
    if (!sameIdentity(identities[1], identities[9])) return error.AuthorityChanged;
    const distinct: [10]files.Identity = .{
        identities[0], identities[1], identities[2], identities[3], identities[4],
        identities[5], identities[6], identities[7], identities[8], identities[10],
    };
    try files.requireDistinct(&distinct);
}

fn sameIdentity(left: files.Identity, right: files.Identity) bool {
    return left.device == right.device and left.inode == right.inode;
}

const SemanticGraphInput = struct {
    preparation_evidence: files.ExecutableObservation,
    preparation_manifest: files.ExecutableObservation,
    aggregate_evidence: files.ExecutableObservation,
    aggregate_dmg: files.ExecutableObservation,
    aggregate_frozen: files.ExecutableObservation,
    aggregate_manifest: files.ExecutableObservation,
    dmg_name: []const u8,
    frozen_name: []const u8,
    evidence_name: []const u8,
};

fn requireSemanticGraphImpl(manifest: *const manifest_mod.Manifest, graph: SemanticGraphInput) !void {
    if (!sameContent(graph.preparation_evidence, graph.aggregate_evidence) or
        sameIdentity(graph.preparation_evidence.identity, graph.aggregate_evidence.identity) or
        !sameObservation(graph.preparation_manifest, graph.aggregate_manifest) or
        manifest.assets.len != 3) return error.AuthorityChanged;

    const observations = [_]files.ExecutableObservation{ graph.aggregate_dmg, graph.aggregate_frozen, graph.aggregate_evidence };
    const roles = [_]manifest_mod.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
    const names = [_][]const u8{ graph.dmg_name, graph.frozen_name, graph.evidence_name };
    for (manifest.assets, observations, roles, names) |asset, observation, role, name| {
        if (asset.role != role or !std.mem.eql(u8, asset.name, name) or asset.size != observation.size or
            !std.mem.eql(u8, asset.sha256, &observation.sha256)) return error.AuthorityChanged;
    }
}

fn sameContent(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return left.size == right.size and std.mem.eql(u8, &left.sha256, &right.sha256);
}

fn sameObservation(left: files.ExecutableObservation, right: files.ExecutableObservation) bool {
    return sameIdentity(left.identity, right.identity) and left.mode == right.mode and sameContent(left, right);
}

fn classifyCloseErrorImpl(err: anyerror) anyerror!phase.CleanupDisposition {
    return switch (err) {
        error.DescriptorCloseFailed => .descriptor_close_failed,
        else => err,
    };
}

fn manifestPath(execution: *const Execution) ![:0]const u8 {
    const len = execution.preparation.path_lens[1];
    if (len == 0 or len >= execution.preparation.paths[1].len) return error.InvalidPath;
    return execution.preparation.paths[1][0..len :0];
}

fn validateInputs(inputs: Inputs, token: []const u8, response: []u8, execution: *const Execution) !void {
    if (!inputs.context.protected_tag or token.len == 0 or response.len == 0) return error.InvalidInput;
    const paths = [_][]const u8{ inputs.paths.preparation, inputs.paths.aggregate, inputs.paths.dmg, inputs.paths.frozen_executable, inputs.cli_path };
    for (paths) |path| if (!canonicalAbsolute(path)) return error.InvalidPath;
    for (paths, 0..) |left, index| for (paths[index + 1 ..]) |right|
        if (sameOrDescendant(left, right) or sameOrDescendant(right, left)) return error.InvalidPath;

    const owner = std.mem.asBytes(execution);
    const values = paths ++ [_][]const u8{
        inputs.context.repository.owner,
        inputs.context.repository.name,
        inputs.context.tag,
        inputs.context.source_commit,
        inputs.context.build.workflow_ref,
        std.mem.asBytes(inputs.cli),
        token,
        response,
    };
    for (values) |value| if (overlaps(owner, value)) return error.InvalidOwner;
    for (values, 0..) |left, index| for (values[index + 1 ..]) |right|
        if (overlaps(left, right)) return error.InvalidOwner;
}

fn canonicalAbsolute(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len < 2 or path.len >= std.fs.max_path_bytes or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    for (path) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn sameOrDescendant(parent: []const u8, child: []const u8) bool {
    return std.mem.eql(u8, parent, child) or (child.len > parent.len and std.mem.startsWith(u8, child, parent) and child[parent.len] == '/');
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}

pub const testing_api = if (builtin.is_test) struct {
    pub const SemanticGraph = SemanticGraphInput;

    pub fn classifyCloseError(err: anyerror) anyerror!phase.CleanupDisposition {
        return classifyCloseErrorImpl(err);
    }

    pub fn requireIdentityGraph(identities: [11]files.Identity) !void {
        return requireIdentityGraphImpl(identities);
    }

    pub fn requireSemanticGraph(manifest: *const manifest_mod.Manifest, graph: SemanticGraph) !void {
        return requireSemanticGraphImpl(manifest, graph);
    }

    pub fn readyScalarsValid(execution: *const Execution) bool {
        return validReadyScalars(execution);
    }

    pub fn driveWith(steps: anytype, transaction: *phase.Transaction) !void {
        return phase.executeWith(steps, transaction);
    }
} else struct {};
