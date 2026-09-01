//! Final current release-manifest observation assembled only from authenticated owners.

const std = @import("std");
const manifest = @import("release_manifest");
const current_input = @import("release_adapter_github_current_manifest_input");
const predecessor_mod = @import("release_adapter_github_manifest_attestation");
const predecessor_assets_mod = @import("release_adapter_github_predecessor_assets");
const current_product = @import("release_adapter_github_current_product");
const current_evidence = @import("release_adapter_github_current_evidence");
const current_files = @import("release_adapter_github_current_asset_files");
const current_attestations = @import("release_adapter_github_current_asset_attestation");
const current_compatibility = @import("release_adapter_github_current_compatibility");
const artifact_attestation = @import("release_adapter_github_attestation");

const role_order = [_]manifest.AssetRole{ .universal_dmg, .frozen_product_executable, .evidence_summary };

pub const Error = error{
    InvalidOwner,
    InvalidCurrent,
    InvalidPredecessor,
    InvalidProduct,
    InvalidEvidence,
    InvalidAssets,
    InvalidCompatibility,
};

pub const CurrentObservation = struct {
    owner: ?*CurrentObservation = null,
    parsed: ?manifest.Parsed = null,

    pub fn value(self: *const @This()) ?*const manifest.Manifest {
        if (self.owner != self) return null;
        return if (self.parsed) |*parsed| parsed.value() else null;
    }

    pub fn deinit(self: *@This()) Error!void {
        if (self.owner != self or self.parsed == null) return error.InvalidOwner;
        self.parsed.?.deinit();
        self.* = .{};
    }
};

pub fn compose(
    allocator: std.mem.Allocator,
    current: *const current_input.CurrentManifestInput,
    predecessor: *const predecessor_mod.AuthenticatedManifest,
    predecessor_assets: *predecessor_assets_mod.AuthenticatedPredecessorAssets,
    product: *const current_product.CurrentProduct,
    evidence: *const current_evidence.CurrentEvidence,
    private_files: *current_files.CurrentAssetFiles,
    attestations: *const current_attestations.CurrentAssetAttestations,
    compatibility: *const current_compatibility.CurrentCompatibility,
    result: *CurrentObservation,
) !void {
    return composeWith(allocator, current, predecessor, predecessor_assets, product, evidence, private_files, attestations, compatibility, result);
}

pub fn composeWith(
    allocator: std.mem.Allocator,
    current: anytype,
    predecessor: anytype,
    predecessor_assets: anytype,
    product: anytype,
    evidence: anytype,
    private_files: anytype,
    attestations: anytype,
    compatibility: anytype,
    result: *CurrentObservation,
) !void {
    const result_bytes = std.mem.asBytes(result);
    if (result.owner != null or result.parsed != null or
        rangesOverlap(result_bytes, std.mem.asBytes(current)) or
        rangesOverlap(result_bytes, std.mem.asBytes(predecessor)) or
        rangesOverlap(result_bytes, std.mem.asBytes(predecessor_assets)) or
        rangesOverlap(result_bytes, std.mem.asBytes(product)) or
        rangesOverlap(result_bytes, std.mem.asBytes(evidence)) or
        rangesOverlap(result_bytes, std.mem.asBytes(private_files)) or
        rangesOverlap(result_bytes, std.mem.asBytes(attestations)) or
        rangesOverlap(result_bytes, std.mem.asBytes(compatibility)))
        return error.InvalidOwner;
    current.revalidate() catch return error.InvalidCurrent;
    const current_view = current.value() orelse return error.InvalidCurrent;
    const candidate = current_view.manifest;
    const current_bytes = current.bytes() orelse return error.InvalidCurrent;
    const current_file = if (current.input) |*value| value else return error.InvalidCurrent;
    const current_attestation = if (current.authenticated.observed) |*value| value else return error.InvalidCurrent;
    if (!validCurrent(candidate, current_view.authority) or !current_attestation.verified)
        return error.InvalidCurrent;

    const predecessor_manifest = predecessor.value() orelse return error.InvalidPredecessor;
    const predecessor_manifest_attestation = if (predecessor.observed) |*value| value else return error.InvalidPredecessor;
    const predecessor_view = predecessor_assets.value() orelse return error.InvalidPredecessor;
    predecessor_assets.downloads.revalidate() catch return error.InvalidPredecessor;
    if (!validPredecessor(candidate, predecessor_manifest, predecessor_view.source_commit))
        return error.InvalidPredecessor;

    const product_view = product.revalidateHeld() catch return error.InvalidProduct;
    const evidence_view = evidence.value() orelse return error.InvalidEvidence;
    const evidence_root = switch (evidence_view.evidence.value()) {
        .upgrade_b => |value| value,
        else => return error.InvalidEvidence,
    };
    const private_view = private_files.revalidate() catch return error.InvalidAssets;
    const attestation_view = attestations.value() orelse return error.InvalidAssets;
    if (!validAttestationContext(candidate, attestation_view.context)) return error.InvalidAssets;
    const compatibility_view = compatibility.value() orelse return error.InvalidCompatibility;

    var asset_observations: [role_order.len]manifest.AssetObservation = undefined;
    for (role_order, 0..) |role, index| {
        const expected = assetForRole(candidate.assets, role) orelse return error.InvalidCurrent;
        const private = private_view.asset(role) orelse return error.InvalidAssets;
        const observed = attestation_view.asset(role) orelse return error.InvalidAssets;
        if (private.role != role or private.mode & 0o170777 != 0o100400 or private.link_count != 1 or
            private.size != expected.size or !std.mem.eql(u8, private.name, expected.name) or
            !std.mem.eql(u8, private.sha256, expected.sha256)) return error.InvalidAssets;
        asset_observations[index] = .{
            .asset = expected,
            .regular_file = true,
            .no_follow = true,
            .attestation = artifactObservation(candidate, observed),
        };
    }

    const predecessor_bytes = try manifest.writeCanonical(allocator, predecessor_manifest.*);
    defer allocator.free(predecessor_bytes);
    var predecessor_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(predecessor_bytes, &predecessor_digest, .{});
    const predecessor_sha = std.fmt.bytesToHex(predecessor_digest, .lower);
    if (!std.mem.eql(u8, &predecessor_sha, candidate.predecessor.?.manifest_sha256))
        return error.InvalidPredecessor;
    var predecessor_name_storage: [manifest.max_asset_name_bytes]u8 = undefined;
    const predecessor_name = std.fmt.bufPrint(&predecessor_name_storage, "Maru-{s}-session-host-release.json", .{predecessor_manifest.release.version}) catch return error.InvalidPredecessor;
    if (!validArtifactReceipt(predecessor_manifest, predecessor_manifest_attestation, predecessor_name, &predecessor_sha))
        return error.InvalidPredecessor;

    const observed: manifest.Observation = .{
        .repository = candidate.repository,
        .release = candidate.release,
        .source = candidate.source,
        .build = candidate.build,
        .executable_sha256 = &compatibility_view.executable_sha256,
        .compatibility = compatibility_view.compatibility,
        .executable_compatibility_verified = true,
        .signing = product_view.apple.signing(),
        .strict_signature_verified = true,
        .notarization_verified = true,
        .staple_verified = true,
        .assets = &asset_observations,
        .dmg_product_executable_sha256 = product_view.apple.executableSha256(),
        .dmg_extraction_no_follow = true,
        .evidence = .{
            .summary_sha256 = evidence_view.summary_sha256,
            .test_uuid = evidence_root.test_uuid,
            .result = @tagName(evidence_root.result),
            .candidate_executable_sha256 = evidence_root.candidate.executable_sha256,
        },
        .evidence_schema_verified = true,
        .manifest_sha256 = &current_file.sha256,
        .manifest_attestation = artifactObservation(candidate, current_attestation),
        .predecessor = .{
            .manifest_bytes = predecessor_bytes,
            .manifest_sha256 = &predecessor_sha,
            .published = true,
            .immutable = true,
            .manifest_asset_count = 1,
            .release_attestation = .{
                .verified = true,
                .repository = predecessor_manifest.repository,
                .release_id = predecessor_manifest.release.id,
                .release_tag = predecessor_manifest.release.tag,
                .source_commit = predecessor_manifest.source.commit,
                .manifest_sha256 = &predecessor_sha,
                .assets = predecessor_manifest.assets,
            },
        },
    };
    var parsed = try manifest.parseAndValidateObservation(allocator, current_bytes, observed);
    errdefer parsed.deinit();
    const product_after = product.revalidateHeld() catch return error.InvalidProduct;
    if (!std.mem.eql(u8, &product_after.frozen.sha256, &product_view.frozen.sha256) or
        !manifest.equalSigning(product_after.apple.signing(), product_view.apple.signing()))
        return error.InvalidProduct;
    const private_after = private_files.revalidate() catch return error.InvalidAssets;
    for (role_order) |role| {
        const before = private_view.asset(role) orelse return error.InvalidAssets;
        const after = private_after.asset(role) orelse return error.InvalidAssets;
        if (before.identity.device != after.identity.device or before.identity.inode != after.identity.inode or
            before.size != after.size or before.mode != after.mode or before.link_count != after.link_count or
            !std.mem.eql(u8, before.name, after.name) or !std.mem.eql(u8, before.sha256, after.sha256))
            return error.InvalidAssets;
    }
    predecessor_assets.downloads.revalidate() catch return error.InvalidPredecessor;
    current.revalidate() catch return error.InvalidCurrent;
    const final_current = current.value() orelse return error.InvalidCurrent;
    const final_attestations = attestations.value() orelse return error.InvalidAssets;
    const final_compatibility = compatibility.value() orelse return error.InvalidCompatibility;
    if (!validCurrent(final_current.manifest, final_current.authority) or
        !validAttestationContext(final_current.manifest, final_attestations.context) or
        !std.mem.eql(u8, &final_compatibility.executable_sha256, &compatibility_view.executable_sha256) or
        !manifest.equalCompatibility(final_compatibility.compatibility, compatibility_view.compatibility) or
        evidence.value() == null or predecessor.value() == null or predecessor_assets.value() == null)
        return error.InvalidCurrent;
    result.* = .{ .owner = result, .parsed = parsed };
}

fn artifactObservation(candidate: *const manifest.Manifest, observed: anytype) manifest.Attestation {
    return .{
        .verified = observed.verified,
        .repository = candidate.repository,
        .source_commit = candidate.source.commit,
        .workflow_ref = candidate.build.workflow_ref,
        .run_id = observed.run_id,
        .run_attempt = observed.run_attempt,
        .subject_name = observed.subject_name,
        .subject_sha256 = observed.subject_sha256,
    };
}

fn validCurrent(candidate: *const manifest.Manifest, authority: anytype) bool {
    return candidate.role == .b and candidate.predecessor != null and authority.protected_environment and
        authority.repository_id == candidate.repository.id and authority.release_id == candidate.release.id and
        authority.run_id == candidate.build.run_id and authority.run_attempt == candidate.build.run_attempt and
        std.mem.eql(u8, authority.tag, candidate.release.tag) and
        std.mem.eql(u8, authority.source_commit, candidate.source.commit);
}

fn validPredecessor(current: *const manifest.Manifest, predecessor: *const manifest.Manifest, source_commit: []const u8) bool {
    const expected = current.predecessor orelse return false;
    return predecessor.role == .a and predecessor.predecessor == null and expected.release_id == predecessor.release.id and
        std.mem.eql(u8, expected.tag, predecessor.release.tag) and std.mem.eql(u8, expected.commit, predecessor.source.commit) and
        std.mem.eql(u8, source_commit, predecessor.source.commit);
}

fn validArtifactReceipt(candidate: *const manifest.Manifest, observed: anytype, name: []const u8, sha256: []const u8) bool {
    return observed.verified and observed.run_id == candidate.build.run_id and
        observed.run_attempt == candidate.build.run_attempt and std.mem.eql(u8, observed.subject_name, name) and
        std.mem.eql(u8, observed.subject_sha256, sha256);
}

fn validAttestationContext(candidate: *const manifest.Manifest, context: current_attestations.ContextView) bool {
    return context.repository_id == candidate.repository.id and context.release_id == candidate.release.id and
        context.run_id == candidate.build.run_id and context.run_attempt == candidate.build.run_attempt and
        std.mem.eql(u8, context.tag, candidate.release.tag) and std.mem.eql(u8, context.source_commit, candidate.source.commit) and
        std.mem.eql(u8, context.workflow_ref, candidate.build.workflow_ref);
}

fn assetForRole(assets: []const manifest.Asset, role: manifest.AssetRole) ?manifest.Asset {
    var found: ?manifest.Asset = null;
    for (assets) |asset| if (asset.role == role) {
        if (found != null) return null;
        found = asset;
    };
    return found;
}

fn rangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_end = std.math.add(usize, @intFromPtr(left.ptr), left.len) catch return true;
    const right_end = std.math.add(usize, @intFromPtr(right.ptr), right.len) catch return true;
    return @intFromPtr(left.ptr) < right_end and @intFromPtr(right.ptr) < left_end;
}
