//! Canonical candidate manifest authoring from a held evidence inode and revalidated authorities.

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("release_manifest");
const evidence = @import("release_evidence");
const files = @import("release_adapter_files");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const source_tree = @import("release_adapter_github_source_tree");
const compatibility_mod = @import("release_adapter_candidate_compatibility");
const predecessor_identity = @import("release_adapter_predecessor_evidence_identity");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const manifest_file = @import("release_adapter_github_manifest_file");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

pub const Paths = struct {
    dmg: [:0]const u8,
    frozen_executable: [:0]const u8,
    evidence: [:0]const u8,
    output: [:0]const u8,
};

/// One revalidated view of the complete typed authority graph. Production adapters construct this
/// from candidate/product/source/compatibility and, for role B, predecessor authorities.
pub const Bundle = struct {
    expected: evidence.Expected,
    designated_requirement_sha256: []const u8,
    value: manifest.Manifest,
};

pub const PredecessorGraph = struct {
    identity: *const predecessor_identity.PredecessorEvidenceIdentity,
    authenticated: *const authenticated_manifest.AuthenticatedManifest,
    held_manifest: *const manifest_file.ManifestFile,
    assets: *const predecessor_assets.AuthenticatedPredecessorAssets,
};

pub fn author(allocator: std.mem.Allocator, context: context_mod.Context, identity: *const candidate_identity.CandidateEvidenceIdentity, candidate: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, candidate_paths: candidate_product.Paths, source: *const source_tree.SourceTreeAuthority, compatibility: *const compatibility_mod.CandidateCompatibility, held_evidence: *const files.PinnedReleaseFile, paths: Paths, predecessor: ?PredecessorGraph, result: *files.PinnedReleaseFile) !void {
    const result_bytes = std.mem.asBytes(result);
    var authority = initAuthority(context, identity, candidate, product, candidate_paths, source, compatibility, predecessor);
    if (authority.aliases(result_bytes) or overlaps(result_bytes, std.mem.asBytes(held_evidence))) return error.InvalidOwner;
    try authorFromAuthority(allocator, &authority, held_evidence, paths, result);
}

pub fn authorWith(allocator: std.mem.Allocator, authority: anytype, held_evidence: *const files.PinnedReleaseFile, paths: Paths, result: *files.PinnedReleaseFile) !void {
    if (!builtin.is_test) @compileError("authorWith is a test-only seam");
    try authorFromAuthority(allocator, authority, held_evidence, paths, result);
}

fn authorFromAuthority(allocator: std.mem.Allocator, authority: anytype, held_evidence: *const files.PinnedReleaseFile, paths: Paths, result: *files.PinnedReleaseFile) !void {
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    if (overlaps(result_bytes, std.mem.asBytes(authority)) or overlaps(result_bytes, std.mem.asBytes(held_evidence))) return error.InvalidOwner;
    inline for (.{ paths.dmg, paths.frozen_executable, paths.evidence, paths.output }) |path| {
        if (!std.fs.path.isAbsolute(path) or overlaps(result_bytes, path)) return error.InvalidPath;
    }
    const path_values = [_][]const u8{ paths.dmg, paths.frozen_executable, paths.evidence, paths.output };
    for (path_values, 0..) |left, index| for (path_values[index + 1 ..]) |right|
        if (std.mem.eql(u8, left, right)) return error.PathAlias;
    if (@hasField(@TypeOf(authority.*), "candidate_paths") and
        (!std.mem.eql(u8, paths.dmg, authority.candidate_paths.dmg) or !std.mem.eql(u8, paths.frozen_executable, authority.candidate_paths.frozen_executable)))
        return error.BindingMismatch;

    var first_input = try held_evidence.readHeldAlloc(allocator, paths.evidence, evidence.max_evidence_bytes);
    defer first_input.deinit(allocator);
    var first_evidence = try evidence.parseCanonical(allocator, first_input.bytes);
    defer first_evidence.deinit();
    const first = try authority.revalidate(first_evidence.profile(), observation(first_input), paths);
    try validateBundleAliases(result_bytes, first);
    try evidence.bind(first_evidence.value(), first.expected);
    try validateAuthorityBinding(first);
    try validateBinding(first.value, first_evidence.profile(), first_input, paths);
    const snapshot = try manifest.writeCanonical(allocator, first.value);
    defer allocator.free(snapshot);
    var self_parsed = try manifest.parseCanonical(allocator, snapshot);
    defer self_parsed.deinit();

    var second_input = try held_evidence.readHeldAlloc(allocator, paths.evidence, evidence.max_evidence_bytes);
    defer second_input.deinit(allocator);
    if (!sameInput(first_input, second_input) or !std.mem.eql(u8, first_input.bytes, second_input.bytes)) return error.EvidenceChanged;
    var second_evidence = try evidence.parseCanonical(allocator, second_input.bytes);
    defer second_evidence.deinit();
    if (second_evidence.profile() != first_evidence.profile()) return error.EvidenceChanged;
    const second = authority.revalidate(second_evidence.profile(), observation(second_input), paths) catch return error.AuthorityChanged;
    try validateBundleAliases(result_bytes, second);
    evidence.bind(second_evidence.value(), second.expected) catch return error.AuthorityChanged;
    validateAuthorityBinding(second) catch return error.AuthorityChanged;
    validateBinding(second.value, second_evidence.profile(), second_input, paths) catch return error.AuthorityChanged;
    const current = manifest.writeCanonical(allocator, second.value) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.AuthorityChanged,
    };
    defer allocator.free(current);
    if (!std.mem.eql(u8, snapshot, current)) return error.AuthorityChanged;

    const before_final = held_evidence.revalidate(paths.evidence) catch return error.EvidenceChanged;
    if (!sameObservation(observation(first_input), before_final)) return error.EvidenceChanged;
    const final = authority.revalidate(second_evidence.profile(), before_final, paths) catch return error.AuthorityChanged;
    try validateBundleAliases(result_bytes, final);
    evidence.bind(second_evidence.value(), final.expected) catch return error.AuthorityChanged;
    validateAuthorityBinding(final) catch return error.AuthorityChanged;
    validateBinding(final.value, second_evidence.profile(), second_input, paths) catch return error.AuthorityChanged;
    if (!sameManifest(self_parsed.value().*, final.value)) return error.AuthorityChanged;
    const after_final = held_evidence.revalidate(paths.evidence) catch return error.EvidenceChanged;
    if (!sameObservation(before_final, after_final)) return error.EvidenceChanged;

    var expected_name: [manifest.max_asset_name_bytes + 32]u8 = undefined;
    const exact = std.fmt.bufPrint(&expected_name, "Maru-{s}-session-host-release.json", .{self_parsed.value().release.version}) catch return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(paths.output), exact)) return error.InvalidPath;
    try files.publishSummaryOwnedExclusive(result, paths.output, snapshot);
}

pub const Authority = struct {
    context: context_mod.Context,
    identity: *const candidate_identity.CandidateEvidenceIdentity,
    candidate: *const candidate_files.CandidateFiles,
    product: *const candidate_product.CandidateProduct,
    candidate_paths: candidate_product.Paths,
    source: *const source_tree.SourceTreeAuthority,
    compatibility: *const compatibility_mod.CandidateCompatibility,
    predecessor: ?PredecessorGraph,
    assets_storage: [3]manifest.Asset = undefined,
    summary_sha: [64]u8 = undefined,

    pub fn aliases(self: *const @This(), bytes: []const u8) bool {
        inline for (.{ self.context.repository.owner, self.context.repository.name, self.context.tag, self.context.source_commit, self.context.build.workflow_ref, std.mem.asBytes(self.identity), std.mem.asBytes(self.candidate), std.mem.asBytes(self.product), std.mem.asBytes(self.source), std.mem.asBytes(self.compatibility), self.candidate_paths.dmg, self.candidate_paths.frozen_executable, self.candidate_paths.dmg_work }) |value|
            if (overlaps(bytes, value)) return true;
        if (self.predecessor) |p| inline for (.{ std.mem.asBytes(p.identity), std.mem.asBytes(p.authenticated), std.mem.asBytes(p.held_manifest), std.mem.asBytes(p.assets) }) |value|
            if (overlaps(bytes, value)) return true;
        return false;
    }

    pub fn revalidate(self: *@This(), profile: evidence.Profile, summary: files.ExecutableObservation, paths: Paths) !Bundle {
        const identity_view = try self.identity.revalidate(self.context, self.candidate, self.product, self.candidate_paths, self.source);
        const product_view = try self.product.revalidate(self.candidate, self.candidate_paths);
        const file_view = try self.candidate.revalidate(.{ .dmg = self.candidate_paths.dmg, .frozen_executable = self.candidate_paths.frozen_executable });
        const compatibility_view = try self.compatibility.revalidate(self.candidate, self.product, self.candidate_paths);
        const signing = product_view.apple.signing();
        if (!std.mem.eql(u8, compatibility_view.executable_sha256, identity_view.common.candidate.executable_sha256)) return error.BindingMismatch;
        self.summary_sha = summary.sha256;
        self.assets_storage = .{
            .{ .role = .universal_dmg, .name = std.fs.path.basename(paths.dmg), .sha256 = identity_view.common.candidate.dmg_sha256, .size = file_view.dmg.size },
            .{ .role = .frozen_product_executable, .name = std.fs.path.basename(paths.frozen_executable), .sha256 = identity_view.common.candidate.executable_sha256, .size = file_view.frozen.size },
            .{ .role = .evidence_summary, .name = std.fs.path.basename(paths.evidence), .sha256 = &self.summary_sha, .size = summary.size },
        };
        var predecessor_value: ?manifest.Predecessor = null;
        const expected: evidence.Expected = switch (profile) {
            .baseline_a => blk: {
                if (self.predecessor != null) return error.RoleMismatch;
                break :blk .{ .baseline_a = identity_view.common };
            },
            .upgrade_b => blk: {
                const graph = self.predecessor orelse return error.RoleMismatch;
                const p = try graph.identity.revalidate(graph.authenticated, graph.held_manifest, graph.assets);
                predecessor_value = .{ .release_id = p.release_id, .tag = p.tag, .commit = p.commit, .manifest_sha256 = p.manifest_sha256 };
                break :blk .{ .upgrade_b = .{ .common = identity_view.common, .predecessor = p, .designated_requirement_sha256 = identity_view.designated_requirement_sha256 } };
            },
        };
        return .{ .expected = expected, .designated_requirement_sha256 = identity_view.designated_requirement_sha256, .value = .{
            .schema = manifest.schema,
            .role = switch (profile) {
                .baseline_a => .a,
                .upgrade_b => .b,
            },
            .repository = .{ .id = identity_view.common.repository.id, .owner = identity_view.common.repository.owner, .name = identity_view.common.repository.name },
            .release = .{ .id = identity_view.common.release.id, .tag = identity_view.common.release.tag, .version = identity_view.common.release.version },
            .source = .{ .commit = identity_view.common.source.commit, .tree = identity_view.common.source.tree },
            .build = .{ .workflow_ref = identity_view.common.build.workflow_ref, .run_id = identity_view.common.build.run_id, .run_attempt = identity_view.common.build.run_attempt },
            .compatibility = compatibility_view.compatibility,
            .signing = signing,
            .assets = &self.assets_storage,
            .evidence = .{ .test_uuid = identity_view.common.test_uuid, .summary_name = std.fs.path.basename(paths.evidence), .summary_sha256 = &self.summary_sha, .result = "passed" },
            .predecessor = predecessor_value,
        } };
    }
};

pub fn initAuthority(context: context_mod.Context, identity: *const candidate_identity.CandidateEvidenceIdentity, candidate: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, candidate_paths: candidate_product.Paths, source: *const source_tree.SourceTreeAuthority, compatibility: *const compatibility_mod.CandidateCompatibility, predecessor: ?PredecessorGraph) Authority {
    return .{ .context = context, .identity = identity, .candidate = candidate, .product = product, .candidate_paths = candidate_paths, .source = source, .compatibility = compatibility, .predecessor = predecessor };
}

/// Rebinds already-canonical authored bytes to the same typed graph used by `author`. This is
/// allocation-free so an attestation caller can repeat it immediately around child execution.
pub fn validateAuthoredSnapshot(authority: *Authority, context: context_mod.Context, parsed_evidence: *const evidence.Parsed, parsed_manifest: *const manifest.Parsed, evidence_observation: files.ExecutableObservation, paths: Paths) !void {
    try context_mod.bindManifest(context, parsed_manifest.value().*);
    const bundle = try authority.revalidate(parsed_evidence.profile(), evidence_observation, paths);
    try evidence.bind(parsed_evidence.value(), bundle.expected);
    try validateAuthorityBinding(bundle);
    try validateBinding(bundle.value, parsed_evidence.profile(), evidence_observation, paths);
    if (!sameManifest(parsed_manifest.value().*, bundle.value)) return error.BindingMismatch;
    var expected_name: [manifest.max_asset_name_bytes + 32]u8 = undefined;
    const exact = std.fmt.bufPrint(&expected_name, "Maru-{s}-session-host-release.json", .{parsed_manifest.value().release.version}) catch return error.InvalidPath;
    if (!std.mem.eql(u8, std.fs.path.basename(paths.output), exact)) return error.InvalidPath;
}

fn validateAuthorityBinding(bundle: Bundle) !void {
    const common: evidence.Common = switch (bundle.expected) {
        .baseline_a => |value| value,
        .upgrade_b => |value| value.common,
    };
    const value = bundle.value;
    if (value.repository.id != common.repository.id or value.release.id != common.release.id or
        value.build.run_id != common.build.run_id or value.build.run_attempt != common.build.run_attempt or
        !eql(value.repository.owner, common.repository.owner) or !eql(value.repository.name, common.repository.name) or
        !eql(value.release.tag, common.release.tag) or !eql(value.release.version, common.release.version) or
        !eql(value.source.commit, common.source.commit) or !eql(value.source.tree, common.source.tree) or
        !eql(value.build.workflow_ref, common.build.workflow_ref) or !eql(value.evidence.test_uuid, common.test_uuid) or
        !eql(value.signing.designated_requirement_sha256, bundle.designated_requirement_sha256) or value.assets.len != 3 or
        !eql(value.assets[0].sha256, common.candidate.dmg_sha256) or !eql(value.assets[1].sha256, common.candidate.executable_sha256))
        return error.BindingMismatch;
    switch (bundle.expected) {
        .baseline_a => if (value.role != .a or value.predecessor != null) return error.BindingMismatch,
        .upgrade_b => |expected| {
            const predecessor = value.predecessor orelse return error.BindingMismatch;
            if (value.role != .b or predecessor.release_id != expected.predecessor.release_id or
                !eql(predecessor.tag, expected.predecessor.tag) or !eql(predecessor.commit, expected.predecessor.commit) or
                !eql(predecessor.manifest_sha256, expected.predecessor.manifest_sha256) or
                !eql(bundle.designated_requirement_sha256, expected.designated_requirement_sha256)) return error.BindingMismatch;
        },
    }
}

fn validateBundleAliases(result_bytes: []const u8, bundle: Bundle) !void {
    if (manifest.aliasesStorage(&bundle.value, result_bytes) or overlaps(result_bytes, bundle.designated_requirement_sha256))
        return error.InvalidOwner;
    const common: evidence.Common = switch (bundle.expected) {
        .baseline_a => |value| value,
        .upgrade_b => |value| value.common,
    };
    const common_values = [_][]const u8{
        common.test_uuid,
        common.repository.owner,
        common.repository.name,
        common.release.tag,
        common.release.version,
        common.source.commit,
        common.source.tree,
        common.build.workflow_ref,
        common.candidate.dmg_sha256,
        common.candidate.executable_sha256,
    };
    for (common_values) |value| if (overlaps(result_bytes, value)) return error.InvalidOwner;
    switch (bundle.expected) {
        .baseline_a => {},
        .upgrade_b => |value| {
            const predecessor_values = [_][]const u8{
                value.predecessor.tag,
                value.predecessor.commit,
                value.predecessor.manifest_sha256,
                value.predecessor.dmg_sha256,
                value.predecessor.executable_sha256,
                value.designated_requirement_sha256,
            };
            for (predecessor_values) |field| if (overlaps(result_bytes, field)) return error.InvalidOwner;
        },
    }
}

fn observation(input: files.Input) files.ExecutableObservation {
    return .{ .identity = input.identity, .size = input.size, .mode = input.mode, .sha256 = input.sha256 };
}

fn validateBinding(value: manifest.Manifest, profile: evidence.Profile, input: anytype, paths: Paths) !void {
    const role: manifest.Role = switch (profile) {
        .baseline_a => .a,
        .upgrade_b => .b,
    };
    if (value.role != role or value.assets.len != 3 or !std.mem.eql(u8, value.evidence.result, "passed") or
        !std.mem.eql(u8, value.evidence.summary_name, std.fs.path.basename(paths.evidence)) or
        !std.mem.eql(u8, value.evidence.summary_sha256, &input.sha256)) return error.BindingMismatch;
    const expected_roles = [_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };
    const expected_names = [_][]const u8{ std.fs.path.basename(paths.dmg), std.fs.path.basename(paths.frozen_executable), std.fs.path.basename(paths.evidence) };
    for (value.assets, 0..) |asset, index|
        if (asset.role != expected_roles[index] or !std.mem.eql(u8, asset.name, expected_names[index])) return error.BindingMismatch;
    if (value.assets[2].size != input.size or !std.mem.eql(u8, value.assets[2].sha256, &input.sha256)) return error.BindingMismatch;
}

fn sameInput(a: files.Input, b: files.Input) bool {
    return a.identity.device == b.identity.device and a.identity.inode == b.identity.inode and a.size == b.size and a.mode == b.mode and std.mem.eql(u8, &a.sha256, &b.sha256);
}
fn sameObservation(a: files.ExecutableObservation, b: files.ExecutableObservation) bool {
    return a.identity.device == b.identity.device and a.identity.inode == b.identity.inode and a.size == b.size and a.mode == b.mode and eql(&a.sha256, &b.sha256);
}
fn sameManifest(a: manifest.Manifest, b: manifest.Manifest) bool {
    if (!eql(a.schema, b.schema) or a.role != b.role or a.repository.id != b.repository.id or
        !eql(a.repository.owner, b.repository.owner) or !eql(a.repository.name, b.repository.name) or
        a.release.id != b.release.id or !eql(a.release.tag, b.release.tag) or !eql(a.release.version, b.release.version) or
        !eql(a.source.commit, b.source.commit) or !eql(a.source.tree, b.source.tree) or
        !eql(a.build.workflow_ref, b.build.workflow_ref) or a.build.run_id != b.build.run_id or a.build.run_attempt != b.build.run_attempt or
        !std.meta.eql(a.compatibility, b.compatibility) or !eql(a.signing.bundle_id, b.signing.bundle_id) or
        !eql(a.signing.bundle_short_version, b.signing.bundle_short_version) or !eql(a.signing.bundle_version, b.signing.bundle_version) or
        !eql(a.signing.team_id, b.signing.team_id) or !eql(a.signing.designated_requirement_sha256, b.signing.designated_requirement_sha256) or
        !eql(a.signing.notarization, b.signing.notarization) or a.signing.stapled != b.signing.stapled or
        a.signing.architectures.len != b.signing.architectures.len or a.assets.len != b.assets.len or
        !eql(a.evidence.test_uuid, b.evidence.test_uuid) or !eql(a.evidence.summary_name, b.evidence.summary_name) or
        !eql(a.evidence.summary_sha256, b.evidence.summary_sha256) or !eql(a.evidence.result, b.evidence.result)) return false;
    for (a.signing.architectures, b.signing.architectures) |left, right| if (!eql(left, right)) return false;
    for (a.assets, b.assets) |left, right| if (left.role != right.role or left.size != right.size or !eql(left.name, right.name) or !eql(left.sha256, right.sha256)) return false;
    if ((a.predecessor == null) != (b.predecessor == null)) return false;
    if (a.predecessor) |left| {
        const right = b.predecessor.?;
        if (left.release_id != right.release_id or !eql(left.tag, right.tag) or !eql(left.commit, right.commit) or !eql(left.manifest_sha256, right.manifest_sha256)) return false;
    }
    return true;
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ae = std.math.add(usize, @intFromPtr(a.ptr), a.len) catch return true;
    const be = std.math.add(usize, @intFromPtr(b.ptr), b.len) catch return true;
    return @intFromPtr(a.ptr) < be and @intFromPtr(b.ptr) < ae;
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
