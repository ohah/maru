//! Trusted upgrade-B evidence publication from revalidated candidate and predecessor identities.

const std = @import("std");
const builtin = @import("builtin");
const evidence = @import("release_evidence");
const evidence_files = @import("release_evidence_files");
const context_mod = @import("release_adapter_context");
const candidate_files = @import("release_adapter_candidate_files");
const candidate_product = @import("release_adapter_candidate_product");
const candidate_identity = @import("release_adapter_candidate_evidence_identity");
const baseline = @import("release_adapter_candidate_baseline_evidence");
const source_tree = @import("release_adapter_github_source_tree");
const predecessor_identity = @import("release_adapter_predecessor_evidence_identity");
const manifest_file = @import("release_adapter_github_manifest_file");
const authenticated_manifest = @import("release_adapter_github_manifest_attestation");
const predecessor_assets = @import("release_adapter_github_predecessor_assets");

pub const PublishedEvidence = evidence_files.PublishedEvidence;
pub const IdentityView = struct { common: evidence.Common, designated_requirement_sha256: []const u8, predecessor: evidence.Predecessor };
pub const Paths = struct { signed_upgrade_one: [:0]const u8, signed_upgrade_near_max: [:0]const u8, output: [:0]const u8 };

pub fn publish(allocator: std.mem.Allocator, context: context_mod.Context, candidate: *const candidate_identity.CandidateEvidenceIdentity, files: *const candidate_files.CandidateFiles, product: *const candidate_product.CandidateProduct, candidate_paths: candidate_product.Paths, source: *const source_tree.SourceTreeAuthority, predecessor: *const predecessor_identity.PredecessorEvidenceIdentity, authenticated: *const authenticated_manifest.AuthenticatedManifest, held_manifest: *const manifest_file.ManifestFile, assets: *const predecessor_assets.AuthenticatedPredecessorAssets, paths: Paths, result: *PublishedEvidence) !void {
    const result_bytes = std.mem.asBytes(result);
    inline for (.{ context.repository.owner, context.repository.name, context.tag, context.source_commit, context.build.workflow_ref, std.mem.asBytes(candidate), std.mem.asBytes(files), std.mem.asBytes(product), std.mem.asBytes(source), std.mem.asBytes(predecessor), std.mem.asBytes(authenticated), std.mem.asBytes(held_manifest), std.mem.asBytes(assets), candidate_paths.dmg, candidate_paths.frozen_executable, candidate_paths.dmg_work }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    var authority = Authority{ .context = context, .candidate = candidate, .files = files, .product = product, .candidate_paths = candidate_paths, .source = source, .predecessor = predecessor, .authenticated = authenticated, .held_manifest = held_manifest, .assets = assets };
    try publishFromAuthority(allocator, &authority, paths, result);
}

pub fn publishWith(allocator: std.mem.Allocator, authority: anytype, paths: Paths, result: *PublishedEvidence) !void {
    if (!builtin.is_test) @compileError("publishWith is a test-only seam");
    try publishFromAuthority(allocator, authority, paths, result);
}

fn publishFromAuthority(allocator: std.mem.Allocator, authority: anytype, paths: Paths, result: *PublishedEvidence) !void {
    if (result.owner != null or result.fd >= 0 or result.parent_fd >= 0) return error.InvalidOwner;
    const result_bytes = std.mem.asBytes(result);
    inline for (.{ std.mem.asBytes(authority), paths.signed_upgrade_one, paths.signed_upgrade_near_max, paths.output }) |value|
        if (overlaps(result_bytes, value)) return error.InvalidOwner;
    const initial = try authority.revalidate();
    try validateViewAliases(result_bytes, initial);
    var snapshot: Snapshot = .{};
    try snapshot.capture(initial);
    var validator = Validator(@TypeOf(authority)){ .authority = authority, .expected = &snapshot, .result_bytes = result_bytes };
    try evidence_files.publishUpgradeOwnedValidated(allocator, .{ .common = snapshot.candidate.common(), .predecessor = snapshot.predecessor.value(), .designated_requirement_sha256 = &snapshot.candidate.designated_requirement_sha256, .one_path = paths.signed_upgrade_one, .near_max_path = paths.signed_upgrade_near_max, .output_path = paths.output }, &validator, result);
}

const Authority = struct {
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
    pub fn revalidate(self: *@This()) !IdentityView {
        const current = try self.candidate.revalidate(self.context, self.files, self.product, self.candidate_paths, self.source);
        return .{ .common = current.common, .designated_requirement_sha256 = current.designated_requirement_sha256, .predecessor = try self.predecessor.revalidate(self.authenticated, self.held_manifest, self.assets) };
    }
};

fn Validator(comptime T: type) type {
    return struct {
        authority: T,
        expected: *const Snapshot,
        result_bytes: []const u8,
        pub fn validate(self: *@This()) !void {
            const current = try self.authority.revalidate();
            try validateViewAliases(self.result_bytes, current);
            if (!self.expected.matches(current)) return error.AuthorityChanged;
        }
    };
}

const PredecessorSnapshot = struct {
    release_id: u64 = 0,
    tag: [evidence.max_scalar_string_bytes]u8 = @splat(0),
    tag_len: usize = 0,
    commit: [40]u8 = @splat(0),
    manifest_sha256: [64]u8 = @splat(0),
    dmg_sha256: [64]u8 = @splat(0),
    executable_sha256: [64]u8 = @splat(0),
    fn capture(self: *@This(), predecessor: evidence.Predecessor) !void {
        if (predecessor.release_id == 0 or predecessor.tag.len > self.tag.len or predecessor.commit.len != 40 or predecessor.manifest_sha256.len != 64 or predecessor.dmg_sha256.len != 64 or predecessor.executable_sha256.len != 64) return error.InvalidIdentity;
        self.release_id = predecessor.release_id;
        self.tag_len = predecessor.tag.len;
        @memcpy(self.tag[0..self.tag_len], predecessor.tag);
        @memcpy(&self.commit, predecessor.commit);
        @memcpy(&self.manifest_sha256, predecessor.manifest_sha256);
        @memcpy(&self.dmg_sha256, predecessor.dmg_sha256);
        @memcpy(&self.executable_sha256, predecessor.executable_sha256);
    }
    fn value(self: *const @This()) evidence.Predecessor {
        return .{ .release_id = self.release_id, .tag = self.tag[0..self.tag_len], .commit = &self.commit, .manifest_sha256 = &self.manifest_sha256, .dmg_sha256 = &self.dmg_sha256, .executable_sha256 = &self.executable_sha256 };
    }
    fn matches(self: *const @This(), other: evidence.Predecessor) bool {
        const expected = self.value();
        return expected.release_id == other.release_id and eql(expected.tag, other.tag) and eql(expected.commit, other.commit) and eql(expected.manifest_sha256, other.manifest_sha256) and eql(expected.dmg_sha256, other.dmg_sha256) and eql(expected.executable_sha256, other.executable_sha256);
    }
};
const Snapshot = struct {
    candidate: baseline.IdentitySnapshot = .{},
    predecessor: PredecessorSnapshot = .{},
    fn capture(self: *@This(), view: IdentityView) !void {
        try self.candidate.capture(.{ .common = view.common, .designated_requirement_sha256 = view.designated_requirement_sha256 });
        try self.predecessor.capture(view.predecessor);
    }
    fn matches(self: *const @This(), view: IdentityView) bool {
        return self.candidate.matches(.{ .common = view.common, .designated_requirement_sha256 = view.designated_requirement_sha256 }) and self.predecessor.matches(view.predecessor);
    }
};
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn validateViewAliases(result_bytes: []const u8, view: IdentityView) !void {
    const values = [_][]const u8{
        view.common.test_uuid,
        view.common.repository.owner,
        view.common.repository.name,
        view.common.release.tag,
        view.common.release.version,
        view.common.source.commit,
        view.common.source.tree,
        view.common.build.workflow_ref,
        view.common.candidate.dmg_sha256,
        view.common.candidate.executable_sha256,
        view.designated_requirement_sha256,
        view.predecessor.tag,
        view.predecessor.commit,
        view.predecessor.manifest_sha256,
        view.predecessor.dmg_sha256,
        view.predecessor.executable_sha256,
    };
    for (values) |value| if (overlaps(result_bytes, value)) return error.InvalidOwner;
}
fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const le = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const re = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < re and @intFromPtr(right.ptr) < le;
}
