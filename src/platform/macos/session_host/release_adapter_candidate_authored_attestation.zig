//! Artifact provenance for the exact aggregate evidence and manifest authored by one candidate.

const std = @import("std");
const builtin = @import("builtin");
const context_mod = @import("release_adapter_context");
const files = @import("release_adapter_files");
const candidate_manifest = @import("release_adapter_candidate_manifest");
const attestation = @import("release_adapter_github_attestation");
const cli_authority = @import("release_adapter_github_cli_authority");
const deadline_mod = @import("release_adapter_deadline");
const evidence_mod = @import("release_evidence");
const manifest_mod = @import("release_manifest");

pub const Paths = struct { evidence: [:0]const u8, manifest: [:0]const u8 };
pub const Cli = struct { path: [:0]const u8, pinned: *const cli_authority.PinnedExecutable };

pub const View = struct {
    repository_id: u64,
    repository_owner: []const u8,
    repository_name: []const u8,
    release_id: u64,
    tag: []const u8,
    source_commit: []const u8,
    workflow_ref: []const u8,
    run_id: u64,
    run_attempt: u64,
    protected_tag: bool,
    evidence: files.ExecutableObservation,
    manifest: files.ExecutableObservation,
    evidence_attested: bool,
    manifest_attested: bool,
};

pub const AuthoredAttestation = struct {
    owner: ?*AuthoredAttestation = null,
    evidence: files.ExecutableObservation = undefined,
    manifest: files.ExecutableObservation = undefined,
    repository_id: u64 = 0,
    repository_owner: [context_mod.max_value_bytes]u8 = @splat(0),
    repository_owner_len: usize = 0,
    repository_name: [context_mod.max_value_bytes]u8 = @splat(0),
    repository_name_len: usize = 0,
    release_id: u64 = 0,
    tag: [context_mod.max_value_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    source_commit: [40]u8 = @splat(0),
    workflow_ref: [context_mod.max_value_bytes]u8 = @splat(0),
    workflow_ref_len: usize = 0,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    protected_tag: bool = false,
    evidence_attested: bool = false,
    manifest_attested: bool = false,

    pub fn value(self: *const @This()) ?View {
        if (self.owner != self or !self.evidence_attested or !self.manifest_attested or self.repository_owner_len > self.repository_owner.len or self.repository_name_len > self.repository_name.len or self.tag_len > self.tag.len or self.workflow_ref_len > self.workflow_ref.len) return null;
        return .{ .repository_id = self.repository_id, .repository_owner = self.repository_owner[0..self.repository_owner_len], .repository_name = self.repository_name[0..self.repository_name_len], .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .source_commit = &self.source_commit, .workflow_ref = self.workflow_ref[0..self.workflow_ref_len], .run_id = self.run_id, .run_attempt = self.run_attempt, .protected_tag = self.protected_tag, .evidence = self.evidence, .manifest = self.manifest, .evidence_attested = true, .manifest_attested = true };
    }

    pub fn revalidate(self: *const @This(), context: context_mod.Context, release_id: u64, evidence: *const files.PinnedReleaseFile, manifest: *const files.PinnedReleaseFile, paths: Paths) !View {
        const expected = self.value() orelse return error.InvalidOwner;
        if (release_id == 0 or expected.release_id != release_id or !sameContext(expected, context)) return error.AuthorityMismatch;
        const current_evidence = evidence.revalidate(paths.evidence) catch return error.FileChanged;
        const current_manifest = manifest.revalidate(paths.manifest) catch return error.FileChanged;
        if (!sameObservation(expected.evidence, current_evidence) or !sameObservation(expected.manifest, current_manifest)) return error.FileChanged;
        try files.requireDistinct(&.{ current_evidence.identity, current_manifest.identity });
        return .{ .repository_id = expected.repository_id, .repository_owner = expected.repository_owner, .repository_name = expected.repository_name, .release_id = expected.release_id, .tag = expected.tag, .source_commit = expected.source_commit, .workflow_ref = expected.workflow_ref, .run_id = expected.run_id, .run_attempt = expected.run_attempt, .protected_tag = expected.protected_tag, .evidence = current_evidence, .manifest = current_manifest, .evidence_attested = true, .manifest_attested = true };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or !self.evidence_attested or !self.manifest_attested) return error.InvalidOwner;
        self.* = .{};
    }
};

const RealCliAuthority = struct {
    pinned: *const cli_authority.PinnedExecutable,
    pub fn revalidate(self: *@This(), allocator: std.mem.Allocator, path: [:0]const u8) !void {
        try cli_authority.revalidate(allocator, path, self.pinned);
    }
};
const RealVerifier = struct {
    pub fn verifyWith(_: *@This(), executor: anytype, allocator: std.mem.Allocator, executable: []const u8, token: []const u8, path: []const u8, expected: attestation.Expected, output: []u8, budget: i128) !attestation.Observed {
        return attestation.verifyWith(executor, allocator, executable, token, path, expected, output, budget);
    }
};
const Semantic = struct {
    authority: *candidate_manifest.Authority,
    evidence: *const evidence_mod.Parsed,
    manifest: *const manifest_mod.Parsed,
    manifest_paths: candidate_manifest.Paths,
    context: context_mod.Context,

    pub fn revalidate(self: *@This(), _: std.mem.Allocator, held_evidence: *const files.PinnedReleaseFile, held_manifest: *const files.PinnedReleaseFile, paths: Paths) !void {
        const evidence_observation = held_evidence.revalidate(paths.evidence) catch return error.FileChanged;
        _ = held_manifest.revalidate(paths.manifest) catch return error.FileChanged;
        try candidate_manifest.validateAuthoredSnapshot(self.authority, self.context, self.evidence, self.manifest, evidence_observation, self.manifest_paths);
    }
};

pub fn composeUntil(io: std.Io, allocator: std.mem.Allocator, context: context_mod.Context, authority: *candidate_manifest.Authority, held_evidence: *const files.PinnedReleaseFile, held_manifest: *const files.PinnedReleaseFile, manifest_paths: candidate_manifest.Paths, cli: Cli, token: []const u8, output: []u8, deadline: *deadline_mod.Deadline, result: *AuthoredAttestation) !void {
    try validateInputs(context, held_evidence, held_manifest, .{ .evidence = manifest_paths.evidence, .manifest = manifest_paths.output }, cli.path, token, output, result);
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(result_bytes, std.mem.asBytes(authority)) or authority.aliases(result_bytes) or overlaps(result_bytes, std.mem.asBytes(cli.pinned)) or overlaps(result_bytes, std.mem.asBytes(deadline)) or
        overlaps(output, std.mem.asBytes(authority)) or authority.aliases(output) or overlaps(output, std.mem.asBytes(cli.pinned)) or overlaps(output, std.mem.asBytes(deadline))) return error.InvalidOwner;
    var evidence_input = try held_evidence.readHeldAlloc(allocator, manifest_paths.evidence, evidence_mod.max_evidence_bytes);
    defer evidence_input.deinit(allocator);
    var parsed_evidence = try evidence_mod.parseCanonical(allocator, evidence_input.bytes);
    defer parsed_evidence.deinit();
    var manifest_input = try held_manifest.readHeldAlloc(allocator, manifest_paths.output, manifest_mod.max_manifest_bytes);
    defer manifest_input.deinit(allocator);
    var parsed_manifest = try manifest_mod.parseCanonical(allocator, manifest_input.bytes);
    defer parsed_manifest.deinit();
    var plan_storage: attestation.ArgsStorage = undefined;
    _ = try attestation.plan(&plan_storage, manifest_paths.evidence, .{ .context = context, .subject_name = std.fs.path.basename(manifest_paths.evidence), .subject_sha256 = &evidence_input.sha256 });
    _ = try attestation.plan(&plan_storage, manifest_paths.output, .{ .context = context, .subject_name = std.fs.path.basename(manifest_paths.output), .subject_sha256 = &manifest_input.sha256 });
    var semantic = Semantic{ .authority = authority, .evidence = &parsed_evidence, .manifest = &parsed_manifest, .manifest_paths = manifest_paths, .context = context };
    var cli_impl = RealCliAuthority{ .pinned = cli.pinned };
    var verifier = RealVerifier{};
    var executor = attestation.BoundedExecutor{ .io = io };
    try composeCore(&semantic, &cli_impl, &verifier, &executor, deadline, allocator, context, parsed_manifest.value().release.id, held_evidence, held_manifest, .{ .evidence = manifest_paths.evidence, .manifest = manifest_paths.output }, cli.path, token, output, result);
}

pub fn composeUntilWith(semantic: anytype, cli_authority_impl: anytype, verifier: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, context: context_mod.Context, release_id: u64, evidence: *const files.PinnedReleaseFile, manifest: *const files.PinnedReleaseFile, paths: Paths, executable: [:0]const u8, token: []const u8, output: []u8, result: *AuthoredAttestation) !void {
    if (!builtin.is_test) @compileError("composeUntilWith is a test-only seam");
    try composeCore(semantic, cli_authority_impl, verifier, executor, deadline, allocator, context, release_id, evidence, manifest, paths, executable, token, output, result);
}

fn composeCore(semantic: anytype, cli_authority_impl: anytype, verifier: anytype, executor: anytype, deadline: anytype, allocator: std.mem.Allocator, context: context_mod.Context, release_id: u64, evidence: *const files.PinnedReleaseFile, manifest: *const files.PinnedReleaseFile, paths: Paths, executable: [:0]const u8, token: []const u8, output: []u8, result: *AuthoredAttestation) !void {
    if (release_id == 0) return error.AuthorityMismatch;
    try validateInputs(context, evidence, manifest, paths, executable, token, output, result);
    if (overlaps(std.mem.asBytes(result), std.mem.asBytes(semantic)) or overlaps(std.mem.asBytes(result), std.mem.asBytes(cli_authority_impl)) or overlaps(std.mem.asBytes(result), std.mem.asBytes(deadline)) or
        overlaps(output, std.mem.asBytes(semantic)) or overlaps(output, std.mem.asBytes(cli_authority_impl)) or overlaps(output, std.mem.asBytes(deadline))) return error.InvalidOwner;
    var published = false;
    defer {
        if (!published) result.* = .{};
    }
    try semantic.revalidate(allocator, evidence, manifest, paths);
    const initial_evidence = evidence.revalidate(paths.evidence) catch return error.FileChanged;
    const initial_manifest = manifest.revalidate(paths.manifest) catch return error.FileChanged;
    try files.requireDistinct(&.{ initial_evidence.identity, initial_manifest.identity });
    const owners = [_]*const files.PinnedReleaseFile{ evidence, manifest };
    const role_paths = [_][:0]const u8{ paths.evidence, paths.manifest };
    var final_observations: [2]files.ExecutableObservation = undefined;
    for (owners, 0..) |owner, index| {
        _ = try deadline.remaining();
        try cli_authority_impl.revalidate(allocator, executable);
        try semantic.revalidate(allocator, evidence, manifest, paths);
        const before = owner.revalidate(role_paths[index]) catch return error.FileChanged;
        const budget = try deadline.remaining();
        var observed = try verifier.verifyWith(executor, allocator, executable, token, role_paths[index], .{ .context = context, .subject_name = std.fs.path.basename(role_paths[index]), .subject_sha256 = &before.sha256 }, output, budget);
        defer observed.deinit(allocator);
        if (!observed.verified or observed.run_id != context.build.run_id or observed.run_attempt != context.build.run_attempt or
            !std.mem.eql(u8, observed.subject_name, std.fs.path.basename(role_paths[index])) or !std.mem.eql(u8, observed.subject_sha256, &before.sha256)) return error.AttestationMismatch;
        try cli_authority_impl.revalidate(allocator, executable);
        try semantic.revalidate(allocator, evidence, manifest, paths);
        const after = owner.revalidate(role_paths[index]) catch return error.FileChanged;
        if (!sameObservation(before, after)) return error.FileChanged;
        final_observations[index] = after;
    }
    try semantic.revalidate(allocator, evidence, manifest, paths);
    const final_evidence = evidence.revalidate(paths.evidence) catch return error.FileChanged;
    const final_manifest = manifest.revalidate(paths.manifest) catch return error.FileChanged;
    if (!sameObservation(final_observations[0], final_evidence) or !sameObservation(final_observations[1], final_manifest)) return error.FileChanged;
    final_observations = .{ final_evidence, final_manifest };
    try files.requireDistinct(&.{ final_observations[0].identity, final_observations[1].identity });
    _ = try deadline.remaining();
    result.* = .{ .owner = result, .repository_id = context.repository.id, .repository_owner_len = context.repository.owner.len, .repository_name_len = context.repository.name.len, .release_id = release_id, .tag_len = context.tag.len, .workflow_ref_len = context.build.workflow_ref.len, .run_id = context.build.run_id, .run_attempt = context.build.run_attempt, .protected_tag = context.protected_tag, .evidence = final_observations[0], .manifest = final_observations[1], .evidence_attested = true, .manifest_attested = true };
    @memcpy(result.repository_owner[0..result.repository_owner_len], context.repository.owner);
    @memcpy(result.repository_name[0..result.repository_name_len], context.repository.name);
    @memcpy(result.tag[0..result.tag_len], context.tag);
    @memcpy(&result.source_commit, context.source_commit);
    @memcpy(result.workflow_ref[0..result.workflow_ref_len], context.build.workflow_ref);
    published = true;
}

fn validateInputs(context: context_mod.Context, evidence: *const files.PinnedReleaseFile, manifest: *const files.PinnedReleaseFile, paths: Paths, executable: []const u8, token: []const u8, output: []u8, result: *const AuthoredAttestation) !void {
    if (result.owner != null or result.evidence_attested or result.manifest_attested) return error.InvalidOwner;
    if (context.repository.owner.len == 0 or context.repository.owner.len > context_mod.max_value_bytes or context.repository.name.len == 0 or context.repository.name.len > context_mod.max_value_bytes or context.tag.len == 0 or context.tag.len > context_mod.max_value_bytes or context.source_commit.len != 40 or context.build.workflow_ref.len == 0 or context.build.workflow_ref.len > context_mod.max_value_bytes) return error.AuthorityMismatch;
    if (!std.fs.path.isAbsolute(paths.evidence) or !std.fs.path.isAbsolute(paths.manifest) or std.mem.eql(u8, paths.evidence, paths.manifest)) return error.InvalidPath;
    if (!std.fs.path.isAbsolute(executable) or !validScalar(executable) or !validScalar(token) or output.len == 0 or output.len > attestation.max_response_bytes) return error.InvalidInput;
    const result_bytes = std.mem.asBytes(result);
    inline for (.{ std.mem.asBytes(evidence), std.mem.asBytes(manifest), context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref, paths.evidence, paths.manifest, executable, token, output }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    if (overlaps(output, std.mem.asBytes(evidence)) or overlaps(output, std.mem.asBytes(manifest)) or overlaps(output, paths.evidence) or overlaps(output, paths.manifest) or overlaps(output, executable) or overlaps(output, token)) return error.InvalidInput;
}

fn sameObservation(a: files.ExecutableObservation, b: files.ExecutableObservation) bool {
    return a.identity.device == b.identity.device and a.identity.inode == b.identity.inode and a.size == b.size and a.mode == b.mode and std.mem.eql(u8, &a.sha256, &b.sha256);
}
fn sameContext(view: View, context: context_mod.Context) bool {
    return view.repository_id == context.repository.id and view.run_id == context.build.run_id and view.run_attempt == context.build.run_attempt and
        view.protected_tag == context.protected_tag and std.mem.eql(u8, view.repository_owner, context.repository.owner) and std.mem.eql(u8, view.repository_name, context.repository.name) and
        std.mem.eql(u8, view.tag, context.tag) and std.mem.eql(u8, view.source_commit, context.source_commit) and std.mem.eql(u8, view.workflow_ref, context.build.workflow_ref);
}
fn validScalar(value: []const u8) bool {
    if (value.len == 0 or value.len > attestation.max_token_bytes) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
